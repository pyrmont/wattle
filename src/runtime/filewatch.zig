//! `spawn`-based filesystem watching: the cfunctions, and the flag vocabulary
//! they translate between Janet keywords and the host's own bits.
//!
//! The flag vocabulary is here rather than beside this file because it has no
//! name Janet publishes and one importer. `filewatch/abi.zig` is where the
//! platform difference actually lives, and `be` below is the one name every
//! call goes through, which is what makes the platform choice a value rather
//! than a conditional at every call.

// ==========================================================================
// Standard library imports
// ==========================================================================

const std = @import("std");

// ==========================================================================
// Project imports
// ==========================================================================

const abstract_type = @import("../api/abstract_type.zig");
const abstracts = @import("value/abstracts.zig");
const args_core = @import("args.zig");
const c = @import("cabi");
const constants = @import("constants");
const corefn = @import("corefn.zig");
const ev_channel = @import("ev/channel.zig");
const ev_loop = @import("ev.zig");
const ev_stream = @import("ev/stream.zig");
const fatal = @import("fatal.zig");
const fibers = @import("value/fibers.zig");
const functions = @import("value/functions.zig");
const fw_abi = @import("filewatch/abi.zig");
const gc_alloc = @import("gc.zig");
const gc_mark = @import("gc/mark.zig");
const host_stat = @import("os/fs/host_stat.zig");
const pp_format = @import("pp/format.zig");
const raise = @import("../api/raise.zig");
const repr = @import("repr");
const stdio = @import("stdio.zig");
const strings = @import("value/strings.zig");
const structs = @import("value/structs.zig");
const tables = @import("value/tables.zig");
const utils = @import("utils.zig");
const value = @import("value.zig");
const vm_lifecycle = @import("vm/lifecycle.zig");
const wrap = @import("value/helpers/wrap.zig");

/// `filewatch/abi.zig`'s translation, which is where every `h.`-qualified
/// name below comes from.
const h = fw_abi.h;

// ==========================================================================
// Constants
// ==========================================================================

/// The backend the call below dispatches to, chosen by `filewatch/abi.zig`.
const backend = fw_abi.backend;

/// The backend this target compiles. Every call in this file goes through this
/// one name.
const be = switch (backend) {
    .inotify => inotify,
    .windows => win,
    .kqueue => kqueue,
    .none => unsupported,
};

/// The platform whose vocabulary this target's backend uses, or nothing where
/// there is no backend and therefore no vocabulary.
const be_platform: ?Platform = switch (backend) {
    .inotify => .linux,
    .windows => .windows,
    .kqueue => .kqueue,
    .none => null,
};

/// The kqueue vocabulary, in the order its value table lists it.
///
/// This is the superset across the BSDs and macOS. Six of these, `close`,
/// `close-write`, `funlock`, `open`, `read` and `truncate`, are conditional on
/// the host defining the matching `NOTE_*` constant, and on a host that does
/// not, the value is zero and a lookup for it is refused.
const kqueue_names = [_][:0]const u8{
    "all",
    "attrib",
    "close",
    "close-write",
    "delete",
    "extend",
    "funlock",
    "link",
    "open",
    "read",
    "rename",
    "revoke",
    "truncate",
    "write",
};

/// The inotify vocabulary, in the order its value table lists it.
///
/// The order is what the value array agrees with, so it must not be disturbed;
/// it is also ascending, which is what the original binary search assumed.
const linux_names = [_][:0]const u8{
    "access",
    "all",
    "attrib",
    "close-nowrite",
    "close-write",
    "create",
    "delete",
    "delete-self",
    "ignored",
    "modify",
    "move-self",
    "moved-from",
    "moved-to",
    "open",
    "q-overflow",
    "unmount",
};

/// `constants.JANET_STREAM_CLOSED`. A watcher whose own descriptor is closed
/// cannot listen and cannot be added to; `listen` is where that is said,
/// because `add` already fails at the call it is made on.
const stream_closed: u32 = @intCast(constants.JANET_STREAM_CLOSED);

/// `constants.JANET_STREAM_READABLE`, which a watcher's own stream is created
/// with.
const stream_readable: u32 = @intCast(constants.JANET_STREAM_READABLE);

/// The watcher's abstract type. Every field after `gcmark` is null, which the
/// structure already defaults them to.
///
/// `pub` for `test/filewatch_core.zig`, which reads the fields directly: every
/// field after `gcmark` being null is what makes a watcher opaque.
pub const watcherType = abstract_type.define(Watcher, .{
    .name = "filewatch/watcher",
    .gcmark = &filewatchMark,
    .gc = if (backend == .kqueue) &filewatchGc else null,
});

/// The Windows `FILE_ACTION_*` names, by code.
const windows_action_names = [_][:0]const u8{
    "unknown",
    "added",
    "removed",
    "modified",
    "renamed-old",
    "renamed-new",
};

/// The `ReadDirectoryChangesW` vocabulary, in the order its value table lists
/// it. `recursive` is Janet's own flag rather than one of the platform's: it
/// decides the watch-subtree argument instead of joining the filter mask.
const windows_names = [_][:0]const u8{
    "all",
    "attributes",
    "creation",
    "dir-name",
    "file-name",
    "last-access",
    "last-write",
    "recursive",
    "security",
    "size",
};

// ==========================================================================
// Types
// ==========================================================================

/// The platform a vocabulary belongs to.
///
/// The numbers are written out because `abi.h` restates the platform chain as
/// an integer rather than reading it back from the predefines, and the two
/// have to agree.
pub const Platform = enum(u32) {
    linux = 0,
    windows = 1,
    kqueue = 2,
};

/// The watcher behind an `os/filewatch` value.
///
/// A plain Zig struct rather than an `extern` one: nothing outside this file
/// reads a field and the abstract is sized with `@sizeOf`. The layout is
/// conditional, since there is no `stream` member on Windows, where a watch
/// owns a handle each rather than the watcher owning one, and `void` is how
/// that member is spelled away.
const Watcher = struct {
    stream: if (backend == .windows) void else ?*ev_stream.Stream,
    watch_descriptors: ?*tables.Table,
    channel: ?*ev_channel.Channel,
    default_flags: u32,
    is_watching: c_int,
    /// kqueue only: the per-path descriptors this watcher opened.
    ///
    /// They are kept here rather than read back out of `watch_descriptors`.
    /// The `gc` callback that closes them runs mid-sweep, and the table is a
    /// collectable block that may already have been freed by then, so a
    /// callback that walked it would be reading a freed table to decide what
    /// to close. This list is an owned allocation the callback frees itself.
    watched_fds: if (backend == .kqueue) std.ArrayListUnmanaged(c_int) else void,
};

/// The inotify backend.
const inotify = struct {
    /// inotify's flag values, in the order `linux_names` below lists them.
    /// The two arrays are one table split in half,
    /// so an edit to either has to be an edit to both; the assertion below
    /// pins this half's length and `test/filewatch_flags.zig` pins the other
    /// half's to the same number.
    const values = [_]u32{
        h.IN_ACCESS,
        h.IN_ALL_EVENTS,
        h.IN_ATTRIB,
        h.IN_CLOSE_NOWRITE,
        h.IN_CLOSE_WRITE,
        h.IN_CREATE,
        h.IN_DELETE,
        h.IN_DELETE_SELF,
        h.IN_IGNORED,
        h.IN_MODIFY,
        h.IN_MOVE_SELF,
        h.IN_MOVED_FROM,
        h.IN_MOVED_TO,
        h.IN_OPEN,
        h.IN_Q_OVERFLOW,
        h.IN_UNMOUNT,
    };

    comptime {
        if (values.len != 16) @compileError("the inotify table is not whole");
    }

    fn decode(options: []const repr.Value) raise.Error!u32 {
        return decodeFlags(options, .linux, &values, "linux");
    }

    fn init(watcher: *Watcher, channel: ?*ev_channel.Channel, default_flags: u32) raise.Error!void {
        const fd = c.retryIntr(h.inotify_init1, .{h.IN_NONBLOCK | h.IN_CLOEXEC});
        if (fd == -1) return raise.panicv(ev_stream.evLasterr());
        watcher.watch_descriptors = tables.new(0);
        watcher.channel = channel;
        watcher.default_flags = default_flags;
        watcher.is_watching = 0;
        watcher.stream = try ev_loop.makeStream(fd, stream_readable, null);
    }

    fn add(watcher: *Watcher, path: [*:0]const u8, flags: u32) raise.Error!void {
        const stream = watcher.stream orelse return raise.panic("watcher closed");
        const result = c.retryIntr(h.inotify_add_watch, .{ stream.handle, path, flags });
        if (result == -1) return raise.panicv(ev_stream.evLasterr());
        const name = value.fromBytes(std.mem.span(path), .string);
        const wd = wrap.fromInteger(result);
        tables.put(watcher.watch_descriptors.?, name, wd);
        tables.put(watcher.watch_descriptors.?, wd, name);
    }

    fn remove(watcher: *Watcher, path: [*:0]const u8) raise.Error!void {
        const stream = watcher.stream orelse return raise.panic("watcher closed");
        const pathv = value.fromBytes(std.mem.span(path), .string);
        const check = tables.get(watcher.watch_descriptors.?, pathv);
        if (!repr.checkType(check, repr.Tag.number)) {
            return raise.panic("bad watch descriptor");
        }
        const watch_handle = wrap.toInteger(check);
        const result = c.retryIntr(h.inotify_rm_watch, .{ stream.handle, watch_handle });
        if (result == -1) return raise.panicv(ev_stream.evLasterr());
        // The two table entries stay in place, so a removed path keeps its
        // descriptor mapping. That is what a program observes.
    }

    /// The event-loop callback that drains a watcher's descriptor. Nothing
    /// here raises: the event loop calls it
    /// with no protected scope of its own, and every failure is reported by
    /// scheduling or cancelling the waiting fiber.
    fn callbackRead(fiber: *fibers.Fiber, event: ev_loop.AsyncEvent) raise.Error!void {
        const stream = fiber.ev_stream.?;
        const watcher: *Watcher = watcherOf(@as(*?*anyopaque, @ptrCast(@alignCast(fiber.ev_state))).*);
        var buf: [1024]u8 = undefined;
        switch (event) {
            constants.AsyncEvent.mark => gc_mark.mark(wrap.fromAbstract(watcher)),
            constants.AsyncEvent.close, constants.AsyncEvent.err => {
                ev_loop.schedule(fiber, wrap.fromNil());
                ev_loop.asyncEnd(fiber);
            },
            constants.AsyncEvent.hup, constants.AsyncEvent.init, constants.AsyncEvent.read => {
                // The loop re-enters the whole block, so `name` is reset once
                // per `read(2)` and not once per event. A second event in the
                // same buffer with no name of its own therefore inherits the
                // previous one's, and that is what a program sees.
                read_more: while (true) {
                    var name = wrap.fromNil();

                    // Assumption - read will never return partial events. From
                    // the documentation: a buffer of `sizeof(struct
                    // inotify_event) + NAME_MAX + 1` is enough to read at
                    // least one event.
                    const nread = c.retryIntr(h.read, .{ stream.handle, &buf, buf.len });

                    if (nread == -1) {
                        if (c.errno() == h.EAGAIN or c.errno() == h.EWOULDBLOCK) break :read_more;
                        try ev_loop.cancel(fiber, ev_stream.evLasterr());
                        fiber.ev_state = null;
                        ev_loop.asyncEnd(fiber);
                        break :read_more;
                    }
                    if (nread < @sizeOf(h.struct_inotify_event)) break :read_more;

                    var cursor: usize = 0;
                    while (cursor < nread) {
                        var inevent: h.struct_inotify_event = undefined;
                        @memcpy(
                            std.mem.asBytes(&inevent),
                            buf[cursor..][0..@sizeOf(h.struct_inotify_event)],
                        );
                        cursor += @sizeOf(h.struct_inotify_event);
                        if (inevent.len != 0) {
                            name = value.fromBytes(std.mem.span(@as([*:0]const u8, @ptrCast(&buf[cursor]))), .string);
                            cursor += inevent.len;
                        }

                        const path = tables.get(
                            watcher.watch_descriptors.?,
                            wrap.fromInteger(inevent.wd),
                        );
                        const kvs = structs.begin(6);
                        structs.put(kvs, value.fromBytes("wd", .keyword), wrap.fromInteger(inevent.wd));
                        structs.put(kvs, value.fromBytes("wd-path", .keyword), path);
                        if (repr.checkType(name, repr.Tag.nil)) {
                            // Watching a file directly, so the path is the
                            // full path: split it into dirname and basename.
                            // `name` is nil here, which is what a path with no
                            // separator reports as its file name.
                            splitPath(kvs, path, path, name);
                        } else {
                            structs.put(kvs, value.fromBytes("dir-name", .keyword), path);
                            structs.put(kvs, value.fromBytes("file-name", .keyword), name);
                        }
                        structs.put(kvs, value.fromBytes("cookie", .keyword), wrap.fromInteger(@as(i32, @bitCast(inevent.cookie))));
                        // Reported in table order, and `structs.put`
                        // overwrites, so the last matching name wins. The zero
                        // check is the absent-constant convention: every
                        // inotify constant is defined, but without it a zero
                        // would match every mask rather than none.
                        const etype = value.fromBytes("type", .keyword);
                        for (values, 0..) |flag, fi| {
                            if (flag != 0 and (inevent.mask & flag) == flag) {
                                structs.put(kvs, etype, value.fromBytes(flagName(.linux, fi).?, .keyword));
                            }
                        }
                        _ = try ev_loop.channelGive(watcher.channel, wrap.fromStruct(structs.end(kvs)));
                    }
                    // Read some more if possible.
                    continue :read_more;
                }
            },
            else => {},
        }
    }

    fn listen(watcher: *Watcher) raise.Error!void {
        if (watcher.is_watching != 0) return raise.panic("already watching");
        watcher.is_watching = 1;
        const thunk = functions.thunkDelay(wrap.fromNil());
        // A delay thunk takes no arguments and is given none, so the arity
        // check cannot reject it.
        const fiber = fibers.new(thunk, 64, &.{}) catch unreachable;
        // The state is one pointer and the runtime frees whatever is handed
        // to it here, which is the whole of the contract.
        const state: *?*anyopaque = @ptrCast(@alignCast(utils.malloc(@sizeOf(?*anyopaque))));
        state.* = watcher;
        try ev_loop.asyncStartFiber(fiber, watcher.stream.?, constants.AsyncMode.reading, &callbackRead, @ptrCast(state));
        gc_alloc.gcroot(wrap.fromAbstract(watcher));
    }

    fn unlisten(watcher: *Watcher) raise.Error!void {
        if (watcher.is_watching == 0) return;
        watcher.is_watching = 0;
        try ev_loop.streamClose(watcher.stream.?);
        _ = gc_alloc.gcunroot(wrap.fromAbstract(watcher));
    }

    fn mark(watcher: *Watcher) void {
        if (watcher.stream) |stream| gc_mark.mark(wrap.fromAbstract(stream));
    }
};

/// The kqueue backend, for macOS and the BSDs.
const kqueue = struct {
    /// Janet's own flag rather than one of the platform's: it is not a
    /// `NOTE_*` value and is masked out before `kevent(2)` sees it. Only the
    /// Windows backend has one; kqueue's table is entirely the host's.
    const note = struct {
        /// A `NOTE_*` the host does not define is zero here, which
        /// `decodeFlags` refuses, exactly as it would refuse a name left out
        /// of the table altogether.
        fn value(comptime name: []const u8) u32 {
            return if (@hasDecl(h, name)) @intCast(@field(h, name)) else 0;
        }
    };

    /// kqueue's `NOTE_*` values, in the order `kqueue_names` below lists them.
    /// See the note on the inotify half.
    const values = [_]u32{
        // `:all` is the union of every `NOTE_*` this host has.
        note.value("NOTE_ATTRIB") | note.value("NOTE_DELETE") | note.value("NOTE_EXTEND") |
            note.value("NOTE_RENAME") | note.value("NOTE_REVOKE") | note.value("NOTE_WRITE") |
            note.value("NOTE_LINK") | note.value("NOTE_CLOSE") | note.value("NOTE_CLOSE_WRITE") |
            note.value("NOTE_OPEN") | note.value("NOTE_READ") | note.value("NOTE_FUNLOCK") |
            note.value("NOTE_TRUNCATE"),
        note.value("NOTE_ATTRIB"),
        note.value("NOTE_CLOSE"),
        note.value("NOTE_CLOSE_WRITE"),
        note.value("NOTE_DELETE"),
        note.value("NOTE_EXTEND"),
        note.value("NOTE_FUNLOCK"),
        note.value("NOTE_LINK"),
        note.value("NOTE_OPEN"),
        note.value("NOTE_READ"),
        note.value("NOTE_RENAME"),
        note.value("NOTE_REVOKE"),
        note.value("NOTE_TRUNCATE"),
        note.value("NOTE_WRITE"),
    };

    comptime {
        if (values.len != 14) @compileError("the kqueue table is not whole");
    }

    /// The per-watcher kqueue state. The cookie starts at zero and counts the
    /// events this watcher has reported, rather than being an inotify cookie:
    /// allocating the state without setting it would derive every cookie from
    /// whatever was in the heap block.
    const State = extern struct {
        watcher: *Watcher,
        cookie: u32,
    };

    /// A kevent identifier as a Janet integer.
    ///
    /// `ident` is pointer-width and the value is narrowed to `i32`. The
    /// truncation is written out because `@intCast` would trap where the
    /// contract wraps; every value that reaches here is a file descriptor and
    /// fits.
    fn wrapIdent(ident: usize) repr.Value {
        return wrap.fromInteger(@as(i32, @bitCast(@as(u32, @truncate(ident)))));
    }

    fn decode(options: []const repr.Value) raise.Error!u32 {
        return decodeFlags(options, .kqueue, &values, "bsd");
    }

    fn init(watcher: *Watcher, channel: ?*ev_channel.Channel, default_flags: u32) raise.Error!void {
        // Unchecked: a failed `kqueue()` becomes a stream over descriptor -1
        // rather than a raise, and that is what a program sees.
        const kq = h.kqueue();
        watcher.watch_descriptors = tables.new(0);
        watcher.channel = channel;
        watcher.default_flags = default_flags;
        watcher.is_watching = 0;
        watcher.watched_fds = .empty;
        watcher.stream = try ev_loop.makeStream(kq, stream_readable, null);
        try ev_loop.levelTriggeredStream(watcher.stream.?);
    }

    fn add(watcher: *Watcher, path: [*:0]const u8, flags: u32) raise.Error!void {
        const stream = watcher.stream orelse return raise.panic("watcher closed");
        const kq = stream.handle;
        const file_fd = c.retryIntr(h.open, .{ path, h.O_RDONLY });
        if (file_fd == -1) return pp_format.panicf("failed to open: %v", .{ev_stream.evLasterr()});
        // Watch for EVFILT_VNODE on the file descriptor.
        var kev: h.struct_kevent = undefined;
        fw_abi.evSetVnode(&kev, file_fd, flags);
        const status = c.retryIntr(h.kevent, .{ kq, &kev, 1, null, 0, null });
        if (status == -1) {
            _ = h.close(file_fd);
            return pp_format.panicf("failed to listen: %v", .{ev_stream.evLasterr()});
        }
        const name = value.fromBytes(std.mem.span(path), .string);
        const wd = wrap.fromInteger(file_fd);
        // Recorded before the table, so that a raise out of `tables.put`,
        // which allocates, cannot strand a descriptor nothing owns.
        watcher.watched_fds.append(utils.heap, file_fd) catch fatal.outOfMemory();
        tables.put(watcher.watch_descriptors.?, name, wd);
        tables.put(watcher.watch_descriptors.?, wd, name);
    }

    fn remove(watcher: *Watcher, path: [*:0]const u8) raise.Error!void {
        if (watcher.stream == null) return raise.panic("watcher closed");
        const pathv = value.fromBytes(std.mem.span(path), .string);
        const check = tables.get(watcher.watch_descriptors.?, pathv);
        if (!repr.checkType(check, repr.Tag.number)) {
            return raise.panic("bad watch descriptor");
        }
        // Closing the file descriptor also removes it from the kqueue.
        const wd = wrap.toInteger(check);
        const result = c.retryIntr(h.close, .{wd});
        if (result == -1) return raise.panicv(ev_stream.evLasterr());
        forgetFd(watcher, wd);
        tables.put(watcher.watch_descriptors.?, pathv, wrap.fromNil());
        tables.put(watcher.watch_descriptors.?, wrap.fromInteger(wd), wrap.fromNil());
    }

    fn callbackRead(fiber: *fibers.Fiber, event: ev_loop.AsyncEvent) raise.Error!void {
        const stream = fiber.ev_stream.?;
        const state: *State = @ptrCast(@alignCast(fiber.ev_state));
        const watcher = state.watcher;
        switch (event) {
            constants.AsyncEvent.mark => gc_mark.mark(wrap.fromAbstract(watcher)),
            constants.AsyncEvent.close, constants.AsyncEvent.err => {
                ev_loop.schedule(fiber, wrap.fromNil());
                ev_loop.asyncEnd(fiber);
            },
            constants.AsyncEvent.hup, constants.AsyncEvent.init => {},
            constants.AsyncEvent.read => {
                // Pump events from the sub kqueue. Extra will be pumped after
                // another event loop rotation.
                const num_events = 512;
                var events: [num_events]h.struct_kevent = undefined;
                const kq = stream.handle;
                const status = c.retryIntr(h.kevent, .{ kq, null, 0, &events, num_events, null });
                if (status == -1) {
                    ev_loop.schedule(fiber, wrap.fromNil());
                    ev_loop.asyncEnd(fiber);
                    return;
                }
                for (events[0..@intCast(status)]) |kev| {
                    state.cookie +%= 6700417;
                    // TODO - avoid stat call here, maybe just when adding
                    // listener?
                    // `host_stat.zig` reads the structure, whose layout and
                    // symbol are per architecture.
                    const is_dir = host_stat.descriptorIsDirectory(@intCast(kev.ident)) orelse continue;
                    const ident = wrapIdent(kev.ident);
                    const path = tables.get(watcher.watch_descriptors.?, ident);
                    // From one rather than zero: index zero is `all`, whose
                    // value is the union of the others and would match
                    // everything. A constant the host does not define is zero
                    // here, and `fflags & 0` is already false, so it is
                    // skipped without a guard.
                    for (values[1..], 1..) |flagcheck, j| {
                        if ((kev.fflags & flagcheck) == 0) continue;
                        const kvs = structs.begin(6);
                        structs.put(kvs, value.fromBytes("wd", .keyword), ident);
                        structs.put(kvs, value.fromBytes("wd-path", .keyword), path);
                        structs.put(kvs, value.fromBytes("cookie", .keyword), wrap.fromNumber(@floatFromInt(state.cookie)));
                        structs.put(kvs, value.fromBytes("type", .keyword), value.fromBytes(flagName(.kqueue, j).?, .keyword));
                        if (is_dir) {
                            // Pass in directly.
                            structs.put(kvs, value.fromBytes("file-name", .keyword), value.fromBytes("", .string));
                            structs.put(kvs, value.fromBytes("dir-name", .keyword), path);
                        } else {
                            // Split path.
                            splitPath(kvs, path, value.fromBytes(".", .string), path);
                        }
                        _ = try ev_loop.channelGive(watcher.channel, wrap.fromStruct(structs.end(kvs)));
                    }
                }
            },
            else => {},
        }
    }

    fn listen(watcher: *Watcher) raise.Error!void {
        if (watcher.is_watching != 0) return raise.panic("already watching");
        watcher.is_watching = 1;
        const thunk = functions.thunkDelay(wrap.fromNil());
        // A delay thunk takes no arguments and is given none.
        const fiber = fibers.new(thunk, 64, &.{}) catch unreachable;
        const state: *State = @ptrCast(@alignCast(utils.malloc(@sizeOf(State))));
        state.watcher = watcher;
        state.cookie = 0;
        try ev_loop.asyncStartFiber(fiber, watcher.stream.?, constants.AsyncMode.reading, &callbackRead, state);
        gc_alloc.gcroot(wrap.fromAbstract(watcher));
    }

    /// Unlistening closes the kqueue, and every per-path descriptor with it:
    /// closing the kqueue leaves the watches registered against nothing, and
    /// the watcher is not usable afterwards, since `listen` refuses it.
    /// Leaving them open would leak one descriptor per `filewatch/add`.
    fn unlisten(watcher: *Watcher) raise.Error!void {
        if (watcher.is_watching == 0) return;
        watcher.is_watching = 0;
        closeWatchedFds(watcher);
        try ev_loop.streamClose(watcher.stream.?);
        _ = gc_alloc.gcunroot(wrap.fromAbstract(watcher));
    }

    fn mark(watcher: *Watcher) void {
        if (watcher.stream) |stream| gc_mark.mark(wrap.fromAbstract(stream));
    }

    /// Drop one descriptor from the owned list. Linear, and the list is the
    /// number of paths one watcher watches.
    fn forgetFd(watcher: *Watcher, fd: c_int) void {
        for (watcher.watched_fds.items, 0..) |held, i| {
            if (held == fd) {
                _ = watcher.watched_fds.swapRemove(i);
                return;
            }
        }
    }

    /// Close every descriptor this watcher opened and release the list. Safe
    /// to call twice: the list is emptied as it goes.
    fn closeWatchedFds(watcher: *Watcher) void {
        for (watcher.watched_fds.items) |fd| _ = c.retryIntr(h.close, .{fd});
        watcher.watched_fds.clearRetainingCapacity();
    }

    /// The `gc` callback. It reads nothing collectable: see `watched_fds`.
    fn gc(watcher: *Watcher) void {
        closeWatchedFds(watcher);
        watcher.watched_fds.deinit(utils.heap);
    }
};

/// The arm for a platform with no backend, whose every entry point raises
/// "filewatch not supported on this platform".
const unsupported = struct {
    const message = "filewatch not supported on this platform";

    fn decode(options: []const repr.Value) raise.Error!u32 {
        _ = options;
        return 0;
    }

    fn init(watcher: *Watcher, channel: ?*ev_channel.Channel, default_flags: u32) raise.Error!void {
        _ = watcher;
        _ = channel;
        _ = default_flags;
        return raise.panic(message);
    }

    fn add(watcher: *Watcher, path: [*:0]const u8, flags: u32) raise.Error!void {
        _ = watcher;
        _ = path;
        _ = flags;
        return raise.panic(message);
    }

    fn remove(watcher: *Watcher, path: [*:0]const u8) raise.Error!void {
        _ = watcher;
        _ = path;
        return raise.panic(message);
    }

    fn listen(watcher: *Watcher) raise.Error!void {
        _ = watcher;
        return raise.panic(message);
    }

    fn unlisten(watcher: *Watcher) raise.Error!void {
        _ = watcher;
        return raise.panic(message);
    }

    /// Nothing, where the other backends' `mark` marks the watcher's stream.
    ///
    /// The field exists on this platform and nothing ever assigns it, because
    /// `init` raises before it could. Marking it would hand the collector an
    /// uninitialised pointer, which is undefined rather than merely wrong.
    /// The path is unreachable either way: a watcher that never initialised
    /// has no root to be marked from.
    fn mark(watcher: *Watcher) void {
        _ = watcher;
    }
};

/// The `ReadDirectoryChangesW` backend.
const win = struct {
    /// The recursive-watch flag, which is Janet's own rather than one of the
    /// platform's: it decides the watch-subtree argument
    /// `ReadDirectoryChangesW` takes fourth instead of joining the filter
    /// mask, and is masked out of what reaches the call.
    const recursive: u32 = 0x100000;

    /// Since the file info padding includes embedded file names, include more
    /// space for data. Manually calculating changes when path names are too
    /// long would also have to be handled, but ideally that is avoided as much
    /// as possible.
    const info_padding = 4096 * 4;

    /// The `ReadDirectoryChangesW` filter values, in the order `windows_names`
    /// below lists them. See the note on the inotify half.
    const values = [_]u32{
        h.FILE_NOTIFY_CHANGE_ATTRIBUTES |
            h.FILE_NOTIFY_CHANGE_CREATION |
            h.FILE_NOTIFY_CHANGE_DIR_NAME |
            h.FILE_NOTIFY_CHANGE_FILE_NAME |
            h.FILE_NOTIFY_CHANGE_LAST_ACCESS |
            h.FILE_NOTIFY_CHANGE_LAST_WRITE |
            h.FILE_NOTIFY_CHANGE_SECURITY |
            h.FILE_NOTIFY_CHANGE_SIZE |
            recursive,
        h.FILE_NOTIFY_CHANGE_ATTRIBUTES,
        h.FILE_NOTIFY_CHANGE_CREATION,
        h.FILE_NOTIFY_CHANGE_DIR_NAME,
        h.FILE_NOTIFY_CHANGE_FILE_NAME,
        h.FILE_NOTIFY_CHANGE_LAST_ACCESS,
        h.FILE_NOTIFY_CHANGE_LAST_WRITE,
        recursive,
        h.FILE_NOTIFY_CHANGE_SECURITY,
        h.FILE_NOTIFY_CHANGE_SIZE,
    };

    comptime {
        if (values.len != 10) @compileError("the windows table is not whole");
    }

    /// `extern` and `overlapped`-first because the runtime
    /// hands the address of this structure to the IOCP and reads the
    /// `OVERLAPPED` back out of the completion.
    const OverlappedWatch = extern struct {
        overlapped: fw_abi.Overlapped,
        stream: ?*ev_stream.Stream,
        watcher: *Watcher,
        fiber: ?*fibers.Fiber,
        dir_path: [*:0]const u8,
        flags: u32,
        /// `uint64_t` rather than a byte array, to ensure alignment.
        buf: [info_padding / @sizeOf(u64)]u64,
    };

    fn decode(options: []const repr.Value) raise.Error!u32 {
        return decodeFlags(options, .windows, &values, "windows filewatch");
    }

    fn init(watcher: *Watcher, channel: ?*ev_channel.Channel, default_flags: u32) raise.Error!void {
        watcher.watch_descriptors = tables.new(0);
        watcher.channel = channel;
        watcher.default_flags = default_flags;
        watcher.is_watching = 0;
    }

    fn readDirChanges(ow: *OverlappedWatch) raise.Error!void {
        const result = h.ReadDirectoryChangesW(
            ow.stream.?.handle,
            @ptrCast(&ow.buf),
            info_padding,
            if ((ow.flags & recursive) != 0) 1 else 0,
            ow.flags & ~recursive,
            null,
            @ptrCast(ow),
            null,
        );
        if (result == 0) return raise.panicv(ev_stream.evLasterr());
    }

    fn callbackRead(fiber: *fibers.Fiber, event: ev_loop.AsyncEvent) raise.Error!void {
        const ow: *OverlappedWatch = @ptrCast(@alignCast(fiber.ev_state));
        const watcher = ow.watcher;
        switch (event) {
            constants.AsyncEvent.init => ev_loop.asyncInFlight(fiber),
            constants.AsyncEvent.mark => {
                gc_mark.mark(wrap.fromAbstract(ow.stream.?));
                if (ow.fiber) |f| gc_mark.mark(wrap.fromFiber(f));
                gc_mark.mark(wrap.fromAbstract(watcher));
                gc_mark.mark(wrap.fromString(ow.dir_path));
            },
            constants.AsyncEvent.close => {
                _ = tables.remove(ow.watcher.watch_descriptors.?, wrap.fromString(ow.dir_path));
            },
            constants.AsyncEvent.err, constants.AsyncEvent.failed => try ev_loop.streamClose(ow.stream.?),
            constants.AsyncEvent.complete => {
                if (watcher.is_watching == 0) {
                    try ev_loop.streamClose(ow.stream.?);
                    return;
                }
                var fni: *h.FILE_NOTIFY_INFORMATION = @ptrCast(@alignCast(&ow.buf));
                while (true) {
                    // Extract the name.
                    var filename: repr.Value = undefined;
                    if (fni.FileNameLength != 0) {
                        const wide: [*]const h.WCHAR = @ptrCast(&fni.FileName);
                        const wide_len: c_int = @intCast(fni.FileNameLength / @sizeOf(h.WCHAR));
                        const nbytes = h.WideCharToMultiByte(h.CP_UTF8, 0, wide, wide_len, null, 0, null, null);
                        assert(@src(), nbytes != 0, "bad utf8 path");
                        const into = strings.begin(@intCast(nbytes));
                        _ = h.WideCharToMultiByte(h.CP_UTF8, 0, wide, wide_len, @ptrCast(into), nbytes, null, null);
                        filename = wrap.fromString(strings.end(into));
                    } else {
                        filename = value.fromBytes("", .string);
                    }

                    const kvs = structs.begin(3);
                    // The lookup reports null for an action code outside the
                    // six, so the fallback is named explicitly rather than
                    // read past the end of a table.
                    const named = actionName(@intCast(fni.Action));
                    const action: [*:0]const u8 = if (named) |name| name.ptr else "unknown";
                    structs.put(kvs, value.fromBytes("type", .keyword), value.fromBytes(std.mem.span(action), .keyword));
                    structs.put(kvs, value.fromBytes("file-name", .keyword), filename);
                    structs.put(kvs, value.fromBytes("dir-name", .keyword), wrap.fromString(ow.dir_path));
                    _ = try ev_loop.channelGive(watcher.channel, wrap.fromStruct(structs.end(kvs)));

                    if (fni.NextEntryOffset == 0) break;
                    const base: [*]u8 = @ptrCast(fni);
                    fni = @ptrCast(@alignCast(base + fni.NextEntryOffset));
                }

                // Make another call to read directory changes. This raises
                // from inside the event loop, and the raise is returned
                // through `try` like any other.
                try readDirChanges(ow);
                ev_loop.asyncInFlight(fiber);
            },
            else => {},
        }
    }

    fn startListening(ow: *OverlappedWatch) raise.Error!void {
        try readDirChanges(ow);
        const stream = ow.stream;
        const thunk = functions.thunkDelay(wrap.fromNil());
        // `.?` here is provable rather than inherited, unlike `net_sockets`'s
        // two: `thunkDelay` builds a funcdef with `min_arity` 0 and
        // `max_arity` INT32_MAX, so the arity check cannot reject zero
        // arguments.
        const fiber = fibers.new(thunk, 64, &.{}) catch unreachable;
        fiber.supervisor_channel = fibers.root().?.supervisor_channel;
        ow.fiber = fiber;
        try ev_loop.asyncStartFiber(fiber, stream.?, constants.AsyncMode.reading, &callbackRead, ow);
    }

    fn add(watcher: *Watcher, path: [*:0]const u8, flags: u32) raise.Error!void {
        const handle = h.CreateFileA(
            path,
            h.FILE_LIST_DIRECTORY | h.GENERIC_READ,
            h.FILE_SHARE_READ | h.FILE_SHARE_WRITE | h.FILE_SHARE_DELETE,
            null,
            h.OPEN_EXISTING,
            h.FILE_FLAG_OVERLAPPED | h.FILE_FLAG_BACKUP_SEMANTICS,
            null,
        );
        if (handle == fw_abi.invalid_handle_value) return raise.panicv(ev_stream.evLasterr());
        const stream = try ev_loop.makeStream(handle, stream_readable, null);
        const ow: *OverlappedWatch = @ptrCast(@alignCast(utils.malloc(@sizeOf(OverlappedWatch))));
        @memset(std.mem.asBytes(ow), 0);
        ow.stream = stream;
        ow.dir_path = strings.cstring(path);
        ow.fiber = null;
        ow.flags = flags | watcher.default_flags;
        ow.watcher = watcher;
        // Do we need this?
        ow.overlapped.as.hEvent = h.CreateEventA(null, 0, 0, null);
        tables.put(
            watcher.watch_descriptors.?,
            wrap.fromString(ow.dir_path),
            wrap.fromPointer(ow),
        );
        if (watcher.is_watching != 0) try startListening(ow);
    }

    fn remove(watcher: *Watcher, path: [*:0]const u8) raise.Error!void {
        const pathv = value.fromBytes(std.mem.span(path), .string);
        const streamv = tables.get(watcher.watch_descriptors.?, pathv);
        if (repr.checkType(streamv, repr.Tag.nil)) {
            return pp_format.panicf("path %v is not being watched", .{pathv});
        }
        _ = tables.remove(watcher.watch_descriptors.?, pathv);
        const ow: *OverlappedWatch = @ptrCast(@alignCast(wrap.toPointer(streamv)));
        try ev_loop.streamClose(ow.stream.?);
    }

    /// Every `OverlappedWatch` in the descriptor table, which is the shape
    /// three of this backend's five entry points share.
    /// Two spellings rather than one generic over the body's error set, and
    /// the reason is a rule rather than taste: `mark` is an abstract type's
    /// `gcmark` callback, and `abstract_type.zig` says such a callback may not
    /// raise. A
    /// single raise-capable `eachWatch` would have put an error union on the
    /// mark path, which is exactly the thing that must not be there.
    fn eachWatch(watcher: *Watcher, comptime body: fn (*OverlappedWatch) void) void {
        const table = watcher.watch_descriptors.?;
        for (0..table.capacity) |i| {
            const kv = &table.slots()[i];
            if (!repr.checkType(kv.value, repr.Tag.pointer)) continue;
            body(@ptrCast(@alignCast(wrap.toPointer(kv.value))));
        }
    }

    fn listen(watcher: *Watcher) raise.Error!void {
        if (watcher.is_watching != 0) return raise.panic("already watching");
        watcher.is_watching = 1;
        const table = watcher.watch_descriptors.?;
        for (0..table.capacity) |i| {
            const kv = &table.slots()[i];
            if (!repr.checkType(kv.value, repr.Tag.pointer)) continue;
            try startListening(@ptrCast(@alignCast(wrap.toPointer(kv.value))));
        }
        gc_alloc.gcroot(wrap.fromAbstract(watcher));
    }

    /// The same walk for a body that raises, which `unlisten` needs and `mark`
    /// may not have.
    fn eachWatchRaising(
        watcher: *Watcher,
        comptime body: fn (*OverlappedWatch) raise.Error!void,
    ) raise.Error!void {
        const table = watcher.watch_descriptors.?;
        for (0..table.capacity) |i| {
            const kv = &table.slots()[i];
            if (!repr.checkType(kv.value, repr.Tag.pointer)) continue;
            try body(@ptrCast(@alignCast(wrap.toPointer(kv.value))));
        }
    }

    fn closeStream(ow: *OverlappedWatch) raise.Error!void {
        try ev_loop.streamClose(ow.stream.?);
    }

    fn unlisten(watcher: *Watcher) raise.Error!void {
        if (watcher.is_watching == 0) return;
        watcher.is_watching = 0;
        try eachWatchRaising(watcher, closeStream);
        tables.clear(watcher.watch_descriptors.?);
        _ = gc_alloc.gcunroot(wrap.fromAbstract(watcher));
    }

    fn markWatch(ow: *OverlappedWatch) void {
        if (ow.fiber) |f| gc_mark.mark(wrap.fromFiber(f));
        gc_mark.mark(wrap.fromAbstract(ow.stream.?));
        gc_mark.mark(wrap.fromString(ow.dir_path));
    }

    fn mark(watcher: *Watcher) void {
        eachWatch(watcher, markWatch);
    }
};

// ==========================================================================
// Public functions
// ==========================================================================

/// The keyword name for a Windows `FILE_ACTION_*` code, or nothing where the
/// code is outside the documented range.
///
/// The C original indexed a six-entry array with the code and had nothing to
/// say about a code beyond it. Reporting nothing instead lets the Windows
/// decoder name the fallback explicitly rather than read past the array.
pub fn actionName(action: u32) ?[:0]const u8 {
    if (action >= windows_action_names.len) return null;
    return windows_action_names[action];
}

/// How many flags a platform names. Each backend asserts its value array
/// against this so that the two halves cannot drift apart unnoticed.
pub fn flagCount(platform: Platform) usize {
    return namesFor(platform).len;
}

/// The position of a flag name in a platform's table, or nothing for a name
/// the platform does not have.
///
/// The keyword arrives as bytes rather than as a C string, because a Janet
/// keyword is length-prefixed and may contain a zero byte. That is also what
/// `utils.cstrcmp` compares, so a match here means what a match means there.
/// The search is linear over at most sixteen entries and does not need the
/// table sorted, which is one standing invariant fewer than a binary search
/// would need.
pub fn flagIndex(platform: Platform, name: []const u8) ?usize {
    for (namesFor(platform), 0..) |entry, index| {
        if (std.mem.eql(u8, name, entry)) return index;
    }
    return null;
}

/// The flag name at a position, or nothing where the position is out of range.
///
/// The value half indexes its own array and does not need this; the assertion
/// does, to check that both halves agree on the order the index refers to, and
/// so does the event decoder, which names the flag it matched.
pub fn flagName(platform: Platform, index: usize) ?[:0]const u8 {
    const names = namesFor(platform);
    if (index >= names.len) return null;
    return names[index];
}

/// Installs the `filewatch/` bindings, in upstream Janet's own registration
/// order.
pub fn libFilewatch(env: *tables.Table) void {
    assertTableIsWhole();
    const table = comptime [_]corefn.Entry{
        corefn.reg("filewatch/new", &cfunMake, @src(), "(filewatch/new channel & default-flags)", "Create a new filewatcher that will give events to a channel channel. See `filewatch/add` for available flags.\n\n" ++
            "When an event is triggered by the filewatcher, a struct containing information will be given to channel as with `ev/give`. " ++
            "The contents of the channel depend on the OS, but will contain some common keys:\n\n" ++
            "* `:type` -- the type of the event that was raised.\n\n" ++
            "* `:file-name` -- the base file name of the file that triggered the event.\n\n" ++
            "* `:dir-name` -- the directory name of the file that triggered the event.\n\n" ++
            "Events also will contain keys specific to the host OS.\n\n" ++
            "Windows has no extra properties on events.\n\n" ++
            "Linux and the BSDs have the following extra properties on events:\n\n" ++
            "* `:wd` -- the integer key returned by `filewatch/add` for the path that triggered this. This is a file descriptor integer on BSD and macos.\n\n" ++
            "* `:wd-path` -- the string path for watched directory of file. For files, will be the same as `:file-name`, and for directories, will be the same as `:dir-name`.\n\n" ++
            "* `:cookie` -- a semi-randomized integer used to associate related events, such as :moved-from and :moved-to events.\n\n" ++
            ""),
        corefn.reg("filewatch/add", &cfunAdd, @src(), "(filewatch/add watcher path flag & more-flags)", "Add a path to the watcher. Available flags depend on the current OS, and are as follows:\n\n" ++
            "Windows/MINGW (flags correspond to `FILE_NOTIFY_CHANGE_*` flags in win32 documentation):\n\n" ++
            "FLAGS\n\n" ++
            "* `:all` - trigger an event for all of the below triggers.\n\n" ++
            "* `:attributes` - `FILE_NOTIFY_CHANGE_ATTRIBUTES`\n\n" ++
            "* `:creation` - `FILE_NOTIFY_CHANGE_CREATION`\n\n" ++
            "* `:dir-name` - `FILE_NOTIFY_CHANGE_DIR_NAME`\n\n" ++
            "* `:last-access` - `FILE_NOTIFY_CHANGE_LAST_ACCESS`\n\n" ++
            "* `:last-write` - `FILE_NOTIFY_CHANGE_LAST_WRITE`\n\n" ++
            "* `:security` - `FILE_NOTIFY_CHANGE_SECURITY`\n\n" ++
            "* `:size` - `FILE_NOTIFY_CHANGE_SIZE`\n\n" ++
            "* `:recursive` - watch subdirectories recursively\n\n" ++
            "Linux (flags correspond to `IN_*` flags from <sys/inotify.h>):\n\n" ++
            "* `:access` - `IN_ACCESS`\n\n" ++
            "* `:all` - `IN_ALL_EVENTS`\n\n" ++
            "* `:attrib` - `IN_ATTRIB`\n\n" ++
            "* `:close-nowrite` - `IN_CLOSE_NOWRITE`\n\n" ++
            "* `:close-write` - `IN_CLOSE_WRITE`\n\n" ++
            "* `:create` - `IN_CREATE`\n\n" ++
            "* `:delete` - `IN_DELETE`\n\n" ++
            "* `:delete-self` - `IN_DELETE_SELF`\n\n" ++
            "* `:ignored` - `IN_IGNORED`\n\n" ++
            "* `:modify` - `IN_MODIFY`\n\n" ++
            "* `:move-self` - `IN_MOVE_SELF`\n\n" ++
            "* `:moved-from` - `IN_MOVED_FROM`\n\n" ++
            "* `:moved-to` - `IN_MOVED_TO`\n\n" ++
            "* `:open` - `IN_OPEN`\n\n" ++
            "* `:q-overflow` - `IN_Q_OVERFLOW`\n\n" ++
            "* `:unmount` - `IN_UNMOUNT`\n\n\n" ++
            "BSDs and macos (flags correspond to `NOTE_*` flags from <sys/event.h>). Not all flags are available on all systems:\n\n" ++
            "* `:all` - `All available NOTE_* flags on the current platform`\n\n" ++
            "* `:attrib` - `NOTE_ATTRIB`\n\n" ++
            "* `:close-write` - `NOTE_CLOSE_WRITE`\n\n" ++
            "* `:close` - `NOTE_CLOSE`\n\n" ++
            "* `:delete` - `NOTE_DELETE`\n\n" ++
            "* `:extend` - `NOTE_EXTEND`\n\n" ++
            "* `:funlock` - `NOTE_FUNLOCK`\n\n" ++
            "* `:link` - `NOTE_LINK`\n\n" ++
            "* `:open` - `NOTE_OPEN`\n\n" ++
            "* `:read` - `NOTE_READ`\n\n" ++
            "* `:rename` - `NOTE_RENAME`\n\n" ++
            "* `:revoke` - `NOTE_REVOKE`\n\n" ++
            "* `:truncate` - `NOTE_TRUNCATE`\n\n" ++
            "* `:write` - `NOTE_WRITE`\n\n\n" ++
            "EVENT TYPES\n\n" ++
            "On Windows, events will have the following possible types:\n\n" ++
            "* `:unknown`\n\n" ++
            "* `:added`\n\n" ++
            "* `:removed`\n\n" ++
            "* `:modified`\n\n" ++
            "* `:renamed-old`\n\n" ++
            "* `:renamed-new`\n\n" ++
            "On Linux and BSDs, events will have a `:type` corresponding to the possible flags, excluding `:all`.\n" ++
            ""),
        corefn.reg("filewatch/remove", &cfunRemove, @src(), "(filewatch/remove watcher path)", "Remove a path from the watcher."),
        corefn.reg("filewatch/listen", &cfunListen, @src(), "(filewatch/listen watcher)", "Listen for changes in the watcher."),
        corefn.reg("filewatch/unlisten", &cfunUnlisten, @src(), "(filewatch/unlisten watcher)", "Stop listening for changes on a given watcher."),
    };
    corefn.install(env, table);
}

// ==========================================================================
// Private functions
// ==========================================================================

/// Aborts with the caller's `@src()` unless `cond`.
fn assert(comptime where: std.builtin.SourceLocation, cond: bool, comptime message: []const u8) void {
    if (cond) return;
    const line = std.fmt.comptimePrint(
        "janet abort at {s}:{d}: {s}\n",
        .{ where.file, where.line, message },
    );
    _ = c.fwrite(line.ptr, 1, line.len, stdio.err());
    c.abort();
}

/// Checks that the two halves of the flag table agree on their length.
///
/// Each half asserts its own length against a literal, 16, 10 and 14, and
/// neither assertion can see the other. This one compares them, which is the
/// thing worth knowing, and it is the only reason the count lookup exists: the
/// loops elsewhere index the value table directly, so a disagreement would
/// otherwise show up as a name read from the wrong row rather than as a fault.
fn assertTableIsWhole() void {
    // `comptime` on the unwrap, not merely on the value: `be.values` does not
    // exist in the no-backend arm, and Zig analyses both branches of a runtime
    // `if` however unreachable one of them is. This is the one place the
    // fourth backend would fail to compile if the guard were ordinary.
    if (comptime be_platform) |platform| {
        assert(
            @src(),
            flagCount(platform) == be.values.len,
            "the two halves of the flag table disagree about its length",
        );
    }
}

/// `(filewatch/add watcher path & flags)`.
fn cfunAdd(argv: []repr.Value) raise.Error!repr.Value {
    try args_core.arity(argv, 2, -1);
    const watcher = try args_core.getAbstract(Watcher, argv, 0, &watcherType);
    // The same refusal `filewatch/listen` makes, so that the three calls give
    // one account of a closed watcher rather than three.
    if (!watcherIsOpen(watcher)) return raise.panic("watcher is closed");
    const path = try args_core.getCString(argv, 1);
    const flags = watcher.default_flags | try be.decode(argv[2..]);
    try be.add(watcher, path, flags);
    return argv[0];
}

/// `(filewatch/listen watcher)`.
fn cfunListen(argv: []repr.Value) raise.Error!repr.Value {
    try args_core.fixarity(argv, 1);
    const watcher = try args_core.getAbstract(Watcher, argv, 0, &watcherType);
    // A closed watcher cannot listen. `filewatch/unlisten` closes the
    // watcher's own descriptor, the inotify instance or the kqueue, and
    // nothing reopens it, so listening again starts a fiber on a closed
    // stream: it reports success, delivers nothing ever again, and keeps the
    // event loop from finishing. `filewatch/add` already fails at the call it
    // is made on; this is the other half.
    if (!watcherIsOpen(watcher)) return raise.panic("watcher is closed");
    try be.listen(watcher);
    return wrap.fromNil();
}

/// `(filewatch/new channel & default-flags)`.
fn cfunMake(argv: []repr.Value) raise.Error!repr.Value {
    try vm_lifecycle.sandboxAssert(vm_lifecycle.Sandbox.of(&.{"fs_read"}));
    try args_core.arity(argv, 1, -1);
    const channel = try ev_loop.getChannel(argv, 0);
    const watcher = watcherOf(abstracts.newFor(Watcher, &watcherType));
    const default_flags = try be.decode(argv[1..]);
    try be.init(watcher, channel, default_flags);
    return wrap.fromAbstract(watcher);
}

/// `(filewatch/remove watcher path)`.
fn cfunRemove(argv: []repr.Value) raise.Error!repr.Value {
    try args_core.fixarity(argv, 2);
    const watcher = try args_core.getAbstract(Watcher, argv, 0, &watcherType);
    if (!watcherIsOpen(watcher)) return raise.panic("watcher is closed");
    // TODO - pass string in directly to avoid extra allocation
    const path = try args_core.getCString(argv, 1);
    try be.remove(watcher, path);
    return argv[0];
}

/// `(filewatch/unlisten watcher)`.
fn cfunUnlisten(argv: []repr.Value) raise.Error!repr.Value {
    try args_core.fixarity(argv, 1);
    const watcher = try args_core.getAbstract(Watcher, argv, 0, &watcherType);
    try be.unlisten(watcher);
    return wrap.fromNil();
}

/// Decodes a list of keywords into one backend's flag mask.
///
/// `values` is the backend's flag values in the table's own order, so the
/// index the lookup reports selects one directly. `what` names the backend in
/// the raise, which is the only part of the message that ever differed between
/// them.
fn decodeFlags(
    options: []const repr.Value,
    platform: Platform,
    values: []const u32,
    comptime what: [*:0]const u8,
) raise.Error!u32 {
    var mask: u32 = 0;
    for (options) |opt| {
        if (!repr.checkType(opt, repr.Tag.keyword)) {
            return pp_format.panicf("expected keyword, got %v", .{opt});
        }
        const keyw = wrap.toKeyword(opt);
        const name = keyw[0..strings.head(keyw).length];
        const index = flagIndex(platform, name) orelse
            return pp_format.panicf("unknown %s flag %v", .{ what, opt });
        if (index >= values.len or values[index] == 0) {
            return pp_format.panicf("unknown %s flag %v", .{ what, opt });
        }
        mask |= values[index];
    }
    return mask;
}

/// Releases what the watcher owns outside the collector's heap.
///
/// Only the kqueue backend has any: a descriptor per watched path, opened by
/// `filewatch/add` and closed by `filewatch/remove` or by
/// `filewatch/unlisten`. A watcher that is added to and then simply dropped
/// reaches neither, which is one descriptor leaked per `filewatch/add`.
///
/// It reads nothing collectable, for the reason `Watcher.watched_fds` gives,
/// and it cannot raise, which is what an abstract type's `gc` slot requires.
fn filewatchGc(watcher: *Watcher, _: usize) void {
    if (watcher.channel == null) return; // Incomplete initialization
    kqueue.gc(watcher);
}

/// Traces the channel and the watch-descriptor table.
fn filewatchMark(watcher: *Watcher, _: usize) void {
    const channel = watcher.channel orelse return; // Incomplete initialization
    be.mark(watcher);
    gc_mark.mark(wrap.fromAbstract(channel));
    gc_mark.mark(wrap.fromTable(watcher.watch_descriptors.?));
}

/// The names a platform's vocabulary is made of.
fn namesFor(platform: Platform) []const [:0]const u8 {
    return switch (platform) {
        .linux => &linux_names,
        .windows => &windows_names,
        .kqueue => &kqueue_names,
    };
}

/// The dirname and basename split that inotify and kqueue both make on a path
/// with no name of its own.
///
/// The two backends agree on the split and disagree on what a path with no
/// separator in it means, so both readings are parameters: inotify reports the
/// whole path as the directory and no file at all, and kqueue reports `.` as
/// the directory and the whole path as the file. Everything else is shared,
/// including scanning from the terminating zero rather than from the last
/// byte, which is what makes a path ending in `/` split on that separator, and
/// it was written out twice in C.
fn splitPath(
    kvs: [*]tables.KV,
    path: repr.Value,
    no_sep_dir: repr.Value,
    no_sep_file: repr.Value,
) void {
    const spath = wrap.toString(path);
    const len = strings.head(spath).length;
    var cursor: u32 = len;
    while (cursor > 0 and spath[cursor] != '/') cursor -= 1;
    if (cursor == 0) {
        structs.put(kvs, value.fromBytes("dir-name", .keyword), no_sep_dir);
        structs.put(kvs, value.fromBytes("file-name", .keyword), no_sep_file);
    } else {
        structs.put(kvs, value.fromBytes("dir-name", .keyword), wrap.fromString(strings.new(spath[0..@intCast(cursor)])));
        structs.put(kvs, value.fromBytes("file-name", .keyword), wrap.fromString(strings.new(spath[@intCast(cursor + 1)..@intCast(len)])));
    }
}

/// Whether the watcher's own instance descriptor is still open.
fn watcherIsOpen(watcher: *const Watcher) bool {
    if (backend == .windows) return true;
    const s = watcher.stream orelse return false;
    return s.flags & stream_closed == 0;
}

/// The watcher behind an abstract's payload pointer.
fn watcherOf(p: ?*anyopaque) *Watcher {
    return @ptrCast(@alignCast(p));
}

// ==========================================================================
// Tests
// ==========================================================================

comptime {
    if (backend != .none) {
        _ = &unsupported.decode;
        _ = &unsupported.init;
        _ = &unsupported.add;
        _ = &unsupported.remove;
        _ = &unsupported.listen;
        _ = &unsupported.unlisten;
        _ = &unsupported.mark;
    }
}

test "every table is ascending" {
    // Upstream Janet binary-searches these tables, so each is required to be
    // sorted there. `flagIndex` does not depend on it, but a table that
    // stopped being sorted would mean the two implementations disagreed about
    // which entries were reachable, so it is worth pinning.
    for ([_][]const [:0]const u8{ &linux_names, &windows_names, &kqueue_names }) |names| {
        for (names[1..], 0..) |entry, i| {
            try std.testing.expect(std.mem.order(u8, names[i], entry) == .lt);
        }
    }
}

test "names resolve to their own positions" {
    for ([_]Platform{ .linux, .windows, .kqueue }) |platform| {
        for (namesFor(platform), 0..) |entry, index| {
            try std.testing.expectEqual(@as(?usize, index), indexOf(platform, entry));
        }
    }
}

test "a name belongs only to its own platform" {
    try std.testing.expect(indexOf(.linux, "recursive") == null);
    try std.testing.expect(indexOf(.windows, "attrib") == null);
    try std.testing.expect(indexOf(.kqueue, "modify") == null);
    // `all` is the one name every backend shares.
    try std.testing.expect(indexOf(.linux, "all") != null);
    try std.testing.expect(indexOf(.windows, "all") != null);
    try std.testing.expect(indexOf(.kqueue, "all") != null);
}

test "a partial or extended name matches nothing" {
    try std.testing.expect(indexOf(.linux, "acces") == null);
    try std.testing.expect(indexOf(.linux, "accessx") == null);
    try std.testing.expect(indexOf(.linux, "") == null);
    try std.testing.expect(indexOf(.kqueue, "close-writ") == null);
    try std.testing.expect(indexOf(.kqueue, "close-writes") == null);
}

test "a name containing a zero byte matches nothing" {
    try std.testing.expect(indexOf(.linux, "all\x00") == null);
    try std.testing.expect(indexOf(.linux, "a\x00ll") == null);
}

test "counts match the tables" {
    try std.testing.expectEqual(@as(usize, 16), flagCount(.linux));
    try std.testing.expectEqual(@as(usize, 10), flagCount(.windows));
    try std.testing.expectEqual(@as(usize, 14), flagCount(.kqueue));
}

test "a position outside a table has no name" {
    try std.testing.expect(flagName(.linux, flagCount(.linux)) == null);
    try std.testing.expect(flagName(.windows, flagCount(.windows)) == null);
    try std.testing.expect(flagName(.kqueue, flagCount(.kqueue)) == null);
}

test "action names cover the documented codes" {
    try std.testing.expect(actionName(6) == null);
    for (windows_action_names, 0..) |expected, code| {
        try std.testing.expectEqualStrings(expected, actionName(@intCast(code)).?);
    }
}

/// `flagIndex` under the name the tests below call it by.
fn indexOf(platform: Platform, name: []const u8) ?usize {
    return flagIndex(platform, name);
}
