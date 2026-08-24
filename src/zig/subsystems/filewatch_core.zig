//! `filewatch.c`: the three backends, the watcher abstract type, the flag
//! decoder over `-Dfilewatch-flags`' vocabularies, the five `filewatch/`
//! cfunctions and `janet_lib_filewatch`. This is Phase 10 Part 15.
//!
//! ## Four implementations, one of which every target compiles
//!
//! The C original selects a backend with a `#ifdef` chain and compiles exactly
//! one: inotify on Linux, `ReadDirectoryChangesW` on Windows, kqueue on macOS
//! and the BSDs, and -- for everything else -- a fourth whose every entry point
//! raises "filewatch not supported on this platform". The chain is a host fact
//! rather than a Janet one, so it stays in the preprocessor:
//! `filewatch_abi.h` reduces it to one integer and `filewatch_abi.zig` to one
//! enumeration, and the `switch` on that enumeration is resolved at compile
//! time. Zig analyses a container's declarations lazily, so the three backends
//! this target does not select are not merely unreachable but unanalysed --
//! which is the same position C is in, and the reason the *names* were split
//! out into `-Dfilewatch-flags` in the first place, where all three are
//! compiled everywhere.
//!
//! ## The split with `-Dfilewatch-flags`, and why it survives
//!
//! Every flag's *value* is a host constant -- `IN_ATTRIB`,
//! `FILE_NOTIFY_CHANGE_SIZE`, `NOTE_EXTEND` -- so the value tables are here,
//! beside the backend that uses them, and the name tables stay behind their
//! own selector. The two halves are one table split down the middle: the index
//! a lookup reports selects a value here. A selector's seam is the C ABI, so
//! the four lookups are reached as ordinary `extern` calls and this file works
//! against either arm of `-Dfilewatch-flags`.
//!
//! A zero in a value table means the host's headers do not define that
//! constant -- the BSDs disagree about six of the `NOTE_*` names -- and
//! `decodeFlags` refuses the name, which is the answer the original gave by
//! leaving the entry out of the table altogether.
//!
//! ## Why this file is jump-transparent
//!
//! Two reasons, and each would be enough on its own. The argument layer sits
//! behind `-Dargs-core`, so `janet_getcstring` and its kin raise by `longjmp`
//! through these frames; and every event-loop entry point this file calls --
//! `janet_stream`, `janet_async_start_fiber`, `janet_channel_give` -- is
//! behind `-Dev-loop`, whose seam is the C ABI under both of its arms. So
//! every descriptor is released on the failing path explicitly, exactly as
//! `filewatch.c` released it, and no `defer` may appear here until Part 17.

const std = @import("std");
const builtin = @import("builtin");
const abi = @import("abi");
const corefn = @import("corefn");
const raise = @import("raise");
const pp_format = @import("pp_format.zig");
const fw_abi = @import("filewatch_abi");

const c = abi.c;
const stdio = @import("stdio.zig");
const evloop = @import("evloop.zig");
const lifecycle = @import("lifecycle.zig");
const arglayer = @import("arglayer.zig");
const abstract_type = @import("abstract_type.zig");
const h = fw_abi.h;
const backend = fw_abi.backend;

const stream_readable: u32 = @intCast(c.JANET_STREAM_READABLE);

inline fn errno() c_int {
    return std.c._errno().*;
}

/// `janet_assert`, which is a macro and does not survive translation.
/// `net_addr.zig` has the same five lines and the same reason.
fn assert(comptime where: std.builtin.SourceLocation, cond: bool, comptime message: []const u8) void {
    if (cond) return;
    const line = std.fmt.comptimePrint(
        "janet abort at {s}:{d}: {s}\n",
        .{ where.file, where.line, message },
    );
    _ = fwrite(line.ptr, 1, line.len, @ptrCast(@alignCast(stdio.err())));
    abort();
}

extern fn fwrite(ptr: [*]const u8, size: usize, n: usize, stream_handle: ?*c.FILE) callconv(.c) usize;
extern fn abort() callconv(.c) noreturn;

// ==========================================================================
// The keyword vocabularies, which live behind `-Dfilewatch-flags`
// ==========================================================================

/// The name half of the flag table, by import.
///
/// Its four lookups were `export fn janet_filewatch_flag_*` and were declared
/// here as `extern fn`s, which is what `filewatch.c` needed and what Phase 11
/// Part 21 retired -- rule 44. The `platform_linux`/`platform_windows`/
/// `platform_kqueue` ordinals went with them: they were this side's copy of
/// `Platform`, kept because a `u32` was the only thing that could cross a
/// C-ABI seam, and a direct call names the tag instead.
const vocab = @import("filewatch_flags.zig");
const Platform = vocab.Platform;

/// `janet_watch_decode_flags`: turn a run of keyword options into a flag mask
/// for one backend.
///
/// `values` is the backend's flag values in the table's own order, so the
/// index the lookup reports selects one directly. `what` names the backend in
/// the raise, which is the only part of the message that ever differed between
/// them.
fn decodeFlags(
    options: [*c]c.Janet,
    n: i32,
    platform: Platform,
    values: []const u32,
    comptime what: [*c]const u8,
) raise.Raising(u32) {
    var mask: u32 = 0;
    var i: i32 = 0;
    while (i < n) : (i += 1) {
        const opt = options[@intCast(i)];
        if (c.janet_checktype(opt, c.JANET_KEYWORD) == 0) {
            return pp_format.panicf("expected keyword, got %v", .{opt});
        }
        const keyw = c.janet_unwrap_keyword(opt);
        const name = keyw[0..@intCast(c.janet_string_length(keyw))];
        const index = vocab.flagIndex(platform, name) orelse
            return pp_format.panicf("unknown %s flag %v", .{ what, opt });
        if (index >= values.len or values[index] == 0) {
            return pp_format.panicf("unknown %s flag %v", .{ what, opt });
        }
        mask |= values[index];
    }
    return mask;
}

// ==========================================================================
// The watcher
// ==========================================================================

/// `JanetWatcher`. A plain Zig struct rather than an `extern` one: nothing
/// outside this file reads a field, the abstract is sized with `@sizeOf`, and
/// the C original's own layout is conditional -- there is no `stream` member
/// on Windows, where a watch owns a handle each rather than the watcher owning
/// one. `void` is how that member is spelled away here.
const JanetWatcher = struct {
    stream: if (backend == .windows) void else ?*c.JanetStream,
    watch_descriptors: ?*c.JanetTable,
    channel: ?*c.JanetChannel,
    default_flags: u32,
    is_watching: c_int,
};

fn watcherOf(p: ?*anyopaque) *JanetWatcher {
    return @ptrCast(@alignCast(p));
}

/// `janet_wrap_integer`, written out. `janet.h` declares the function beside
/// its macro and `wrap.c` defines it only for the two nanbox layouts, so a
/// tagged build has no such symbol. This is the tenth subsystem to meet it and
/// `FOUND.md` records it; `-Dnanbox=false` in the matrix is what catches it.
inline fn wrapInteger(x: anytype) c.Janet {
    return c.janet_wrap_number(@floatFromInt(x));
}

// ==========================================================================
// inotify
// ==========================================================================

const inotify = struct {
    /// inotify's flag values, in the order `filewatch_flags.zig`'s
    /// `linux_names` lists them. The two arrays are one table split in half,
    /// so an edit to either has to be an edit to both; the assertion below
    /// pins this half's length and `test/filewatch_flags.c` pins the other
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

    fn decode(options: [*c]c.Janet, n: i32) raise.Raising(u32) {
        return decodeFlags(options, n, .linux, &values, "linux");
    }

    fn init(watcher: *JanetWatcher, channel: ?*c.JanetChannel, default_flags: u32) raise.Raising(void) {
        var fd: c_int = undefined;
        while (true) {
            fd = h.inotify_init1(h.IN_NONBLOCK | h.IN_CLOEXEC);
            if (!(fd == -1 and errno() == h.EINTR)) break;
        }
        if (fd == -1) return raise.panicv(c.janet_ev_lasterr());
        watcher.watch_descriptors = c.janet_table(0);
        watcher.channel = channel;
        watcher.default_flags = default_flags;
        watcher.is_watching = 0;
        watcher.stream = try evloop.makeStream(fd, stream_readable, null);
    }

    fn add(watcher: *JanetWatcher, path: [*c]const u8, flags: u32) raise.Raising(void) {
        const stream = watcher.stream orelse return raise.panic("watcher closed");
        var result: c_int = undefined;
        while (true) {
            result = h.inotify_add_watch(stream.handle, path, flags);
            if (!(result == -1 and errno() == h.EINTR)) break;
        }
        if (result == -1) return raise.panicv(c.janet_ev_lasterr());
        const name = c.janet_cstringv(path);
        const wd = wrapInteger(result);
        c.janet_table_put(watcher.watch_descriptors, name, wd);
        c.janet_table_put(watcher.watch_descriptors, wd, name);
    }

    fn remove(watcher: *JanetWatcher, path: [*c]const u8) raise.Raising(void) {
        const stream = watcher.stream orelse return raise.panic("watcher closed");
        const pathv = c.janet_cstringv(path);
        const check = c.janet_table_get(watcher.watch_descriptors, pathv);
        if (c.janet_checktype(check, c.JANET_NUMBER) == 0) {
            return raise.panic("bad watch descriptor");
        }
        const watch_handle = c.janet_unwrap_integer(check);
        // The condition is `result != -1`, not `result == -1`, and that is
        // `filewatch.c`'s exactly: a *successful* call is retried whenever
        // `errno` happens to hold EINTR from something earlier. `FOUND.md` has
        // the entry; the rule is that defined behaviour is reproduced even
        // when it is a defect.
        var result: c_int = undefined;
        while (true) {
            result = h.inotify_rm_watch(stream.handle, watch_handle);
            if (!(result != -1 and errno() == h.EINTR)) break;
        }
        if (result == -1) return raise.panicv(c.janet_ev_lasterr());
        // The C original leaves the two table entries in place, commented out
        // rather than deleted, so a removed path keeps its descriptor mapping.
    }

    /// `watcher_callback_read`. Nothing here raises: the event loop calls it
    /// with no protected scope of its own, and every failure is reported by
    /// scheduling or cancelling the waiting fiber.
    fn callbackRead(fiber: [*c]c.JanetFiber, event: c.JanetAsyncEvent) raise.Raising(void) {
        const stream = fiber.*.ev_stream;
        const watcher: *JanetWatcher = watcherOf(@as(*?*anyopaque, @ptrCast(@alignCast(fiber.*.ev_state))).*);
        var buf: [1024]u8 = undefined;
        switch (event) {
            c.JANET_ASYNC_EVENT_MARK => c.janet_mark(c.janet_wrap_abstract(watcher)),
            c.JANET_ASYNC_EVENT_CLOSE, c.JANET_ASYNC_EVENT_ERR => {
                c.janet_schedule(fiber, c.janet_wrap_nil());
                c.janet_async_end(fiber);
            },
            c.JANET_ASYNC_EVENT_HUP, c.JANET_ASYNC_EVENT_INIT, c.JANET_ASYNC_EVENT_READ => {
                // `goto read_more`: the C original re-enters the whole block,
                // so `name` is reset once per `read(2)` and not once per
                // event. A second event in the same buffer with no name of its
                // own therefore inherits the previous one's, which is the
                // original's behaviour and is reproduced.
                read_more: while (true) {
                    var name = c.janet_wrap_nil();

                    // Assumption - read will never return partial events. From
                    // the documentation: a buffer of `sizeof(struct
                    // inotify_event) + NAME_MAX + 1` is enough to read at
                    // least one event.
                    var nread: isize = undefined;
                    while (true) {
                        nread = h.read(stream.*.handle, &buf, buf.len);
                        if (!(nread == -1 and errno() == h.EINTR)) break;
                    }

                    if (nread == -1) {
                        if (errno() == h.EAGAIN or errno() == h.EWOULDBLOCK) break :read_more;
                        try evloop.cancel(fiber, c.janet_ev_lasterr());
                        fiber.*.ev_state = null;
                        c.janet_async_end(fiber);
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
                            name = c.janet_cstringv(@as([*c]const u8, @ptrCast(&buf[cursor])));
                            cursor += inevent.len;
                        }

                        const path = c.janet_table_get(
                            watcher.watch_descriptors,
                            wrapInteger(inevent.wd),
                        );
                        const kvs = c.janet_struct_begin(6);
                        c.janet_struct_put(kvs, c.janet_ckeywordv("wd"), wrapInteger(inevent.wd));
                        c.janet_struct_put(kvs, c.janet_ckeywordv("wd-path"), path);
                        if (c.janet_checktype(name, c.JANET_NIL) != 0) {
                            // Watching a file directly, so the path is the
                            // full path: split it into dirname and basename.
                            // `name` is nil here, which is what a path with no
                            // separator reports as its file name.
                            splitPath(kvs, path, path, name);
                        } else {
                            c.janet_struct_put(kvs, c.janet_ckeywordv("dir-name"), path);
                            c.janet_struct_put(kvs, c.janet_ckeywordv("file-name"), name);
                        }
                        c.janet_struct_put(kvs, c.janet_ckeywordv("cookie"), wrapInteger(@as(i32, @bitCast(inevent.cookie))));
                        // Reported in table order, and `janet_struct_put`
                        // overwrites, so the last matching name wins as it did
                        // before. The zero check is for the absent-constant
                        // convention; every inotify constant is defined, but
                        // without it a zero would match every mask rather than
                        // none.
                        const etype = c.janet_ckeywordv("type");
                        for (values, 0..) |flag, fi| {
                            if (flag != 0 and (inevent.mask & flag) == flag) {
                                c.janet_struct_put(kvs, etype, c.janet_ckeywordv(
                                    vocab.flagName(.linux, fi).?.ptr,
                                ));
                            }
                        }
                        _ = try evloop.channelGive(watcher.channel, c.janet_wrap_struct(c.janet_struct_end(kvs)));
                    }
                    // Read some more if possible.
                    continue :read_more;
                }
            },
            else => {},
        }
    }

    fn listen(watcher: *JanetWatcher) raise.Raising(void) {
        if (watcher.is_watching != 0) return raise.panic("already watching");
        watcher.is_watching = 1;
        const thunk = c.janet_thunk_delay(c.janet_wrap_nil());
        const fiber = c.janet_fiber(thunk, 64, 0, null);
        // Gross, and the C original says so: the state is one pointer, and the
        // runtime frees whatever is handed to it here.
        const state: *?*anyopaque = @ptrCast(@alignCast(c.janet_malloc(@sizeOf(?*anyopaque))));
        state.* = watcher;
        try evloop.asyncStartFiber(fiber, watcher.stream.?, c.JANET_ASYNC_LISTEN_READ, &callbackRead, @ptrCast(state));
        c.janet_gcroot(c.janet_wrap_abstract(watcher));
    }

    fn unlisten(watcher: *JanetWatcher) raise.Raising(void) {
        if (watcher.is_watching == 0) return;
        watcher.is_watching = 0;
        try evloop.streamClose(watcher.stream.?);
        _ = c.janet_gcunroot(c.janet_wrap_abstract(watcher));
    }

    fn mark(watcher: *JanetWatcher) void {
        c.janet_mark(c.janet_wrap_abstract(watcher.stream));
    }
};

// ==========================================================================
// kqueue
// ==========================================================================

const kqueue = struct {
    /// Janet's own flag rather than one of the platform's: it is not a
    /// `NOTE_*` value and is masked out before `kevent(2)` sees it. Only the
    /// Windows backend has one; kqueue's table is entirely the host's.
    const note = struct {
        /// A `NOTE_*` the host does not define is zero here, which
        /// `decodeFlags` refuses -- the same answer the original gave by
        /// leaving the entry out of the table altogether.
        fn value(comptime name: []const u8) u32 {
            return if (@hasDecl(h, name)) @intCast(@field(h, name)) else 0;
        }
    };

    /// kqueue's `NOTE_*` values, in the order `filewatch_flags.zig`'s
    /// `kqueue_names` lists them. See the note on the inotify half.
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

    /// `KqueueWatcherState`. The C original allocates this with
    /// `janet_malloc` and sets only `watcher`, so every cookie it reports is
    /// derived from uninitialised heap. Reading it is undefined rather than
    /// merely wrong, so there is nothing to reproduce and the port starts from
    /// zero; `FOUND.md` has the entry.
    const State = extern struct {
        watcher: *JanetWatcher,
        cookie: u32,
    };

    /// `janet_wrap_integer(kev.ident)`. `ident` is a `uintptr_t`, and C
    /// narrows it to `int32_t` on the way in; `@intCast` would trap where C
    /// wraps, so the truncation is written out. Every value that reaches here
    /// is a file descriptor and fits, which is why this is fidelity rather
    /// than a behaviour worth having.
    fn wrapIdent(ident: usize) c.Janet {
        return wrapInteger(@as(i32, @bitCast(@as(u32, @truncate(ident)))));
    }

    fn decode(options: [*c]c.Janet, n: i32) raise.Raising(u32) {
        return decodeFlags(options, n, .kqueue, &values, "bsd");
    }

    fn init(watcher: *JanetWatcher, channel: ?*c.JanetChannel, default_flags: u32) raise.Raising(void) {
        // Unchecked, as in the C original: a failed `kqueue()` becomes a
        // stream over descriptor -1 rather than a raise.
        const kq = h.kqueue();
        watcher.watch_descriptors = c.janet_table(0);
        watcher.channel = channel;
        watcher.default_flags = default_flags;
        watcher.is_watching = 0;
        watcher.stream = try evloop.makeStream(kq, stream_readable, null);
        try evloop.levelTriggeredStream(watcher.stream.?);
    }

    fn add(watcher: *JanetWatcher, path: [*c]const u8, flags: u32) raise.Raising(void) {
        const stream = watcher.stream orelse return raise.panic("watcher closed");
        const kq = stream.handle;
        var file_fd: c_int = undefined;
        while (true) {
            file_fd = h.open(path, h.O_RDONLY);
            if (!(file_fd == -1 and errno() == h.EINTR)) break;
        }
        if (file_fd == -1) return pp_format.panicf("failed to open: %v", .{c.janet_ev_lasterr()});
        // Watch for EVFILT_VNODE on the file descriptor.
        var kev: h.struct_kevent = undefined;
        fw_abi.evSetVnode(&kev, file_fd, flags);
        var status: c_int = undefined;
        while (true) {
            status = h.kevent(kq, &kev, 1, null, 0, null);
            if (!(status == -1 and errno() == h.EINTR)) break;
        }
        if (status == -1) {
            _ = h.close(file_fd);
            return pp_format.panicf("failed to listen: %v", .{c.janet_ev_lasterr()});
        }
        const name = c.janet_cstringv(path);
        const wd = wrapInteger(file_fd);
        c.janet_table_put(watcher.watch_descriptors, name, wd);
        c.janet_table_put(watcher.watch_descriptors, wd, name);
    }

    fn remove(watcher: *JanetWatcher, path: [*c]const u8) raise.Raising(void) {
        if (watcher.stream == null) return raise.panic("watcher closed");
        const pathv = c.janet_cstringv(path);
        const check = c.janet_table_get(watcher.watch_descriptors, pathv);
        if (c.janet_checktype(check, c.JANET_NUMBER) == 0) {
            return raise.panic("bad watch descriptor");
        }
        // Closing the file descriptor also removes it from the kqueue.
        const wd = c.janet_unwrap_integer(check);
        // `result != -1` rather than `result == -1`, which is the C original's
        // condition: a *successful* `close(2)` is retried whenever `errno`
        // happens to hold EINTR from something earlier, and the retry closes a
        // descriptor this watcher no longer owns. `FOUND.md` has the entry.
        var result: c_int = undefined;
        while (true) {
            result = h.close(wd);
            if (!(result != -1 and errno() == h.EINTR)) break;
        }
        if (result == -1) return raise.panicv(c.janet_ev_lasterr());
        c.janet_table_put(watcher.watch_descriptors, pathv, c.janet_wrap_nil());
        c.janet_table_put(watcher.watch_descriptors, wrapInteger(wd), c.janet_wrap_nil());
    }

    fn callbackRead(fiber: [*c]c.JanetFiber, event: c.JanetAsyncEvent) raise.Raising(void) {
        const stream = fiber.*.ev_stream;
        const state: *State = @ptrCast(@alignCast(fiber.*.ev_state));
        const watcher = state.watcher;
        switch (event) {
            c.JANET_ASYNC_EVENT_MARK => c.janet_mark(c.janet_wrap_abstract(watcher)),
            c.JANET_ASYNC_EVENT_CLOSE, c.JANET_ASYNC_EVENT_ERR => {
                c.janet_schedule(fiber, c.janet_wrap_nil());
                c.janet_async_end(fiber);
            },
            c.JANET_ASYNC_EVENT_HUP, c.JANET_ASYNC_EVENT_INIT => {},
            c.JANET_ASYNC_EVENT_READ => {
                // Pump events from the sub kqueue. Extra will be pumped after
                // another event loop rotation.
                const num_events = 512;
                var events: [num_events]h.struct_kevent = undefined;
                const kq = stream.*.handle;
                var status: c_int = undefined;
                while (true) {
                    status = h.kevent(kq, null, 0, &events, num_events, null);
                    if (!(status == -1 and errno() == h.EINTR)) break;
                }
                if (status == -1) {
                    c.janet_schedule(fiber, c.janet_wrap_nil());
                    c.janet_async_end(fiber);
                    return;
                }
                var i: usize = 0;
                while (i < status) : (i += 1) {
                    state.cookie +%= 6700417;
                    const kev = events[i];
                    // TODO - avoid stat call here, maybe just when adding
                    // listener?
                    var stat_buf: h.struct_stat = std.mem.zeroes(h.struct_stat);
                    var st: c_int = undefined;
                    while (true) {
                        st = h.fstat(@intCast(kev.ident), &stat_buf);
                        if (!(st == -1 and errno() == h.EINTR)) break;
                    }
                    if (st == -1) continue;
                    const is_dir = fw_abi.isDir(stat_buf.st_mode);
                    const ident = wrapIdent(kev.ident);
                    const path = c.janet_table_get(watcher.watch_descriptors, ident);
                    // From one rather than zero: index zero is `all`, whose
                    // value is the union of the others and would match
                    // everything. A constant the host does not define is zero
                    // here, and `fflags & 0` is already false, so it is
                    // skipped without a guard.
                    for (values[1..], 1..) |flagcheck, j| {
                        if ((kev.fflags & flagcheck) == 0) continue;
                        const kvs = c.janet_struct_begin(6);
                        c.janet_struct_put(kvs, c.janet_ckeywordv("wd"), ident);
                        c.janet_struct_put(kvs, c.janet_ckeywordv("wd-path"), path);
                        c.janet_struct_put(kvs, c.janet_ckeywordv("cookie"), c.janet_wrap_number(@floatFromInt(state.cookie)));
                        c.janet_struct_put(kvs, c.janet_ckeywordv("type"), c.janet_ckeywordv(
                            vocab.flagName(.kqueue, j).?.ptr,
                        ));
                        if (is_dir) {
                            // Pass in directly.
                            c.janet_struct_put(kvs, c.janet_ckeywordv("file-name"), c.janet_cstringv(""));
                            c.janet_struct_put(kvs, c.janet_ckeywordv("dir-name"), path);
                        } else {
                            // Split path.
                            splitPath(kvs, path, c.janet_cstringv("."), path);
                        }
                        _ = try evloop.channelGive(watcher.channel, c.janet_wrap_struct(c.janet_struct_end(kvs)));
                    }
                }
            },
            else => {},
        }
    }

    fn listen(watcher: *JanetWatcher) raise.Raising(void) {
        if (watcher.is_watching != 0) return raise.panic("already watching");
        watcher.is_watching = 1;
        const thunk = c.janet_thunk_delay(c.janet_wrap_nil());
        const fiber = c.janet_fiber(thunk, 64, 0, null);
        const state: *State = @ptrCast(@alignCast(c.janet_malloc(@sizeOf(State))));
        state.watcher = watcher;
        state.cookie = 0;
        try evloop.asyncStartFiber(fiber, watcher.stream.?, c.JANET_ASYNC_LISTEN_READ, &callbackRead, state);
        c.janet_gcroot(c.janet_wrap_abstract(watcher));
    }

    fn unlisten(watcher: *JanetWatcher) raise.Raising(void) {
        if (watcher.is_watching == 0) return;
        watcher.is_watching = 0;
        try evloop.streamClose(watcher.stream.?);
        _ = c.janet_gcunroot(c.janet_wrap_abstract(watcher));
    }

    fn mark(watcher: *JanetWatcher) void {
        c.janet_mark(c.janet_wrap_abstract(watcher.stream));
    }
};

// ==========================================================================
// `ReadDirectoryChangesW`
// ==========================================================================

const win = struct {
    /// `WATCHFLAG_RECURSIVE`. Janet's own flag rather than one of the
    /// platform's: it selects `ReadDirectoryChangesW`'s `bWatchSubtree`
    /// argument instead of joining the filter mask, and is masked out of the
    /// mask that reaches the call.
    const recursive: u32 = 0x100000;

    /// Since the file info padding includes embedded file names, include more
    /// space for data. Manually calculating changes when path names are too
    /// long would also have to be handled, but ideally that is avoided as much
    /// as possible.
    const info_padding = 4096 * 4;

    /// The `ReadDirectoryChangesW` filter values, in the order
    /// `filewatch_flags.zig`'s `windows_names` lists them. See the note on the
    /// inotify half.
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

    /// `OverlappedWatch`. `extern` and `overlapped`-first because the runtime
    /// hands the address of this structure to the IOCP and reads the
    /// `OVERLAPPED` back out of the completion.
    const OverlappedWatch = extern struct {
        overlapped: fw_abi.JanetOverlapped,
        stream: ?*c.JanetStream,
        watcher: *JanetWatcher,
        fiber: ?*c.JanetFiber,
        dir_path: [*c]const u8,
        flags: u32,
        /// `uint64_t` rather than a byte array, to ensure alignment.
        buf: [info_padding / @sizeOf(u64)]u64,
    };

    fn decode(options: [*c]c.Janet, n: i32) raise.Raising(u32) {
        return decodeFlags(options, n, .windows, &values, "windows filewatch");
    }

    fn init(watcher: *JanetWatcher, channel: ?*c.JanetChannel, default_flags: u32) raise.Raising(void) {
        watcher.watch_descriptors = c.janet_table(0);
        watcher.channel = channel;
        watcher.default_flags = default_flags;
        watcher.is_watching = 0;
    }

    fn readDirChanges(ow: *OverlappedWatch) raise.Raising(void) {
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
        if (result == 0) return raise.panicv(c.janet_ev_lasterr());
    }

    fn callbackRead(fiber: [*c]c.JanetFiber, event: c.JanetAsyncEvent) raise.Raising(void) {
        const ow: *OverlappedWatch = @ptrCast(@alignCast(fiber.*.ev_state));
        const watcher = ow.watcher;
        switch (event) {
            c.JANET_ASYNC_EVENT_INIT => c.janet_async_in_flight(fiber),
            c.JANET_ASYNC_EVENT_MARK => {
                c.janet_mark(c.janet_wrap_abstract(ow.stream));
                c.janet_mark(c.janet_wrap_fiber(ow.fiber));
                c.janet_mark(c.janet_wrap_abstract(watcher));
                c.janet_mark(c.janet_wrap_string(ow.dir_path));
            },
            c.JANET_ASYNC_EVENT_CLOSE => {
                _ = c.janet_table_remove(ow.watcher.watch_descriptors, c.janet_wrap_string(ow.dir_path));
            },
            c.JANET_ASYNC_EVENT_ERR, c.JANET_ASYNC_EVENT_FAILED => try evloop.streamClose(ow.stream.?),
            c.JANET_ASYNC_EVENT_COMPLETE => {
                if (watcher.is_watching == 0) {
                    try evloop.streamClose(ow.stream.?);
                    return;
                }
                var fni: *h.FILE_NOTIFY_INFORMATION = @ptrCast(@alignCast(&ow.buf));
                while (true) {
                    // Extract the name.
                    var filename: c.Janet = undefined;
                    if (fni.FileNameLength != 0) {
                        const wide: [*c]const h.WCHAR = @ptrCast(&fni.FileName);
                        const wide_len: c_int = @intCast(fni.FileNameLength / @sizeOf(h.WCHAR));
                        const nbytes = h.WideCharToMultiByte(h.CP_UTF8, 0, wide, wide_len, null, 0, null, null);
                        assert(@src(), nbytes != 0, "bad utf8 path");
                        const into = c.janet_string_begin(nbytes);
                        _ = h.WideCharToMultiByte(h.CP_UTF8, 0, wide, wide_len, @ptrCast(into), nbytes, null, null);
                        filename = c.janet_wrap_string(c.janet_string_end(into));
                    } else {
                        filename = c.janet_cstringv("");
                    }

                    const kvs = c.janet_struct_begin(3);
                    // The original indexed a six-entry array with the action
                    // code and had nothing to say about a code outside it. The
                    // lookup reports null there instead, so name the fallback
                    // explicitly rather than read past the end.
                    const named = vocab.actionName(@intCast(fni.Action));
                    const action: [*c]const u8 = if (named) |name| name.ptr else "unknown";
                    c.janet_struct_put(kvs, c.janet_ckeywordv("type"), c.janet_ckeywordv(action));
                    c.janet_struct_put(kvs, c.janet_ckeywordv("file-name"), filename);
                    c.janet_struct_put(kvs, c.janet_ckeywordv("dir-name"), c.janet_wrap_string(ow.dir_path));
                    _ = try evloop.channelGive(watcher.channel, c.janet_wrap_struct(c.janet_struct_end(kvs)));

                    if (fni.NextEntryOffset == 0) break;
                    const base: [*]u8 = @ptrCast(fni);
                    fni = @ptrCast(@alignCast(base + fni.NextEntryOffset));
                }

                // Make another call to read directory changes. The C original
                // raises from inside the event loop here, which is where the
                // jump goes; the face is the same one a cfunction would use.
                try readDirChanges(ow);
                c.janet_async_in_flight(fiber);
            },
            else => {},
        }
    }

    fn startListening(ow: *OverlappedWatch) raise.Raising(void) {
        try readDirChanges(ow);
        const stream = ow.stream;
        const thunk = c.janet_thunk_delay(c.janet_wrap_nil());
        const fiber = c.janet_fiber(thunk, 64, 0, null);
        fiber.*.supervisor_channel = c.janet_root_fiber().*.supervisor_channel;
        ow.fiber = fiber;
        try evloop.asyncStartFiber(fiber, stream.?, c.JANET_ASYNC_LISTEN_READ, &callbackRead, ow);
    }

    fn add(watcher: *JanetWatcher, path: [*c]const u8, flags: u32) raise.Raising(void) {
        const handle = h.CreateFileA(
            path,
            h.FILE_LIST_DIRECTORY | h.GENERIC_READ,
            h.FILE_SHARE_READ | h.FILE_SHARE_WRITE | h.FILE_SHARE_DELETE,
            null,
            h.OPEN_EXISTING,
            h.FILE_FLAG_OVERLAPPED | h.FILE_FLAG_BACKUP_SEMANTICS,
            null,
        );
        if (handle == fw_abi.invalid_handle_value) return raise.panicv(c.janet_ev_lasterr());
        const stream = try evloop.makeStream(handle, stream_readable, null);
        const ow: *OverlappedWatch = @ptrCast(@alignCast(c.janet_malloc(@sizeOf(OverlappedWatch))));
        @memset(std.mem.asBytes(ow), 0);
        ow.stream = stream;
        ow.dir_path = c.janet_cstring(path);
        ow.fiber = null;
        ow.flags = flags | watcher.default_flags;
        ow.watcher = watcher;
        // Do we need this?
        ow.overlapped.as.hEvent = h.CreateEventA(null, 0, 0, null);
        c.janet_table_put(
            watcher.watch_descriptors,
            c.janet_wrap_string(ow.dir_path),
            c.janet_wrap_pointer(ow),
        );
        if (watcher.is_watching != 0) try startListening(ow);
    }

    fn remove(watcher: *JanetWatcher, path: [*c]const u8) raise.Raising(void) {
        const pathv = c.janet_cstringv(path);
        const streamv = c.janet_table_get(watcher.watch_descriptors, pathv);
        if (c.janet_checktype(streamv, c.JANET_NIL) != 0) {
            return pp_format.panicf("path %v is not being watched", .{pathv});
        }
        _ = c.janet_table_remove(watcher.watch_descriptors, pathv);
        const ow: *OverlappedWatch = @ptrCast(@alignCast(c.janet_unwrap_pointer(streamv)));
        try evloop.streamClose(ow.stream.?);
    }

    /// Every `OverlappedWatch` in the descriptor table, which is the shape
    /// three of this backend's five entry points share.
    /// Two spellings rather than one generic over the body's error set, and
    /// the reason is a rule rather than taste: `mark` is an abstract type's
    /// `gcmark` callback, and SPIKE-8 says such a callback may not raise. A
    /// single raise-capable `eachWatch` would have put an error union on the
    /// mark path, which is exactly the thing that must not be there.
    fn eachWatch(watcher: *JanetWatcher, comptime body: fn (*OverlappedWatch) void) void {
        const table = watcher.watch_descriptors.?;
        var i: i32 = 0;
        while (i < table.capacity) : (i += 1) {
            const kv = &table.data[@intCast(i)];
            if (c.janet_checktype(kv.value, c.JANET_POINTER) == 0) continue;
            body(@ptrCast(@alignCast(c.janet_unwrap_pointer(kv.value))));
        }
    }

    fn listen(watcher: *JanetWatcher) raise.Raising(void) {
        if (watcher.is_watching != 0) return raise.panic("already watching");
        watcher.is_watching = 1;
        const table = watcher.watch_descriptors.?;
        var i: i32 = 0;
        while (i < table.capacity) : (i += 1) {
            const kv = &table.data[@intCast(i)];
            if (c.janet_checktype(kv.value, c.JANET_POINTER) == 0) continue;
            try startListening(@ptrCast(@alignCast(c.janet_unwrap_pointer(kv.value))));
        }
        c.janet_gcroot(c.janet_wrap_abstract(watcher));
    }

    /// The same walk for a body that raises, which `unlisten` needs and `mark`
    /// may not have.
    fn eachWatchRaising(
        watcher: *JanetWatcher,
        comptime body: fn (*OverlappedWatch) raise.Raising(void),
    ) raise.Raising(void) {
        const table = watcher.watch_descriptors.?;
        var i: i32 = 0;
        while (i < table.capacity) : (i += 1) {
            const kv = &table.data[@intCast(i)];
            if (c.janet_checktype(kv.value, c.JANET_POINTER) == 0) continue;
            try body(@ptrCast(@alignCast(c.janet_unwrap_pointer(kv.value))));
        }
    }

    fn closeStream(ow: *OverlappedWatch) raise.Raising(void) {
        try evloop.streamClose(ow.stream.?);
    }

    fn unlisten(watcher: *JanetWatcher) raise.Raising(void) {
        if (watcher.is_watching == 0) return;
        watcher.is_watching = 0;
        try eachWatchRaising(watcher, closeStream);
        c.janet_table_clear(watcher.watch_descriptors);
        _ = c.janet_gcunroot(c.janet_wrap_abstract(watcher));
    }

    fn markWatch(ow: *OverlappedWatch) void {
        c.janet_mark(c.janet_wrap_fiber(ow.fiber));
        c.janet_mark(c.janet_wrap_abstract(ow.stream));
        c.janet_mark(c.janet_wrap_string(ow.dir_path));
    }

    fn mark(watcher: *JanetWatcher) void {
        eachWatch(watcher, markWatch);
    }
};

// ==========================================================================
// The platform with no backend
// ==========================================================================

const unsupported = struct {
    const message = "filewatch not supported on this platform";

    fn decode(options: [*c]c.Janet, n: i32) raise.Raising(u32) {
        _ = options;
        _ = n;
        return 0;
    }

    fn init(watcher: *JanetWatcher, channel: ?*c.JanetChannel, default_flags: u32) raise.Raising(void) {
        _ = watcher;
        _ = channel;
        _ = default_flags;
        return raise.panic(message);
    }

    fn add(watcher: *JanetWatcher, path: [*c]const u8, flags: u32) raise.Raising(void) {
        _ = watcher;
        _ = path;
        _ = flags;
        return raise.panic(message);
    }

    fn remove(watcher: *JanetWatcher, path: [*c]const u8) raise.Raising(void) {
        _ = watcher;
        _ = path;
        return raise.panic(message);
    }

    fn listen(watcher: *JanetWatcher) raise.Raising(void) {
        _ = watcher;
        return raise.panic(message);
    }

    fn unlisten(watcher: *JanetWatcher) raise.Raising(void) {
        _ = watcher;
        return raise.panic(message);
    }

    /// Nothing, where `janet_filewatch_mark`'s non-Windows arm would mark
    /// `watcher->stream`.
    ///
    /// The field exists on this platform -- C spells it `#ifndef
    /// JANET_WINDOWS` -- and nothing ever assigns it, because `init` raises
    /// before it could. So the C original's mark would read an uninitialised
    /// pointer and hand it to the collector, which is undefined rather than
    /// merely wrong, and Phase 8's sixth rule says the port gets it right
    /// instead of reproducing it. The path is unreachable either way: a
    /// watcher that never initialised has no root to be marked from.
    fn mark(watcher: *JanetWatcher) void {
        _ = watcher;
    }
};

// The platform with no backend is compiled on every target, not only on the
// ones that have no backend.
//
// Nothing in it is host-specific -- seven functions that raise one message --
// so there is no reason for it to be the one implementation no configuration
// this project builds ever compiles, which is what it is in C. Zig analyses a
// container's declarations lazily, and a plain `_ = unsupported` does not
// reach a function body; taking the address of each one does.
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

/// The backend this target compiles. Every call below goes through this one
/// name, which is what turns the C file's `#ifdef` chain into a value.
const be = switch (backend) {
    .inotify => inotify,
    .windows => win,
    .kqueue => kqueue,
    .none => unsupported,
};

/// The platform whose vocabulary this target's backend uses, or null where
/// there is no backend and therefore no vocabulary.
const be_platform: ?Platform = switch (backend) {
    .inotify => .linux,
    .windows => .windows,
    .kqueue => .kqueue,
    .none => null,
};

/// The two halves of the flag table agree on their length.
///
/// Each half asserts its own length against a literal -- 16, 10, 14 -- and
/// neither assertion can see the other. This one compares them, which is the
/// thing worth knowing, and it is the only reason the count lookup exists: the
/// loops above index the value table directly, so a disagreement would
/// otherwise show up as a name read from the wrong row rather than as a
/// fault.
fn assertTableIsWhole() void {
    // `comptime` on the unwrap, not merely on the value: `be.values` does not
    // exist in the no-backend arm, and Zig analyses both branches of a runtime
    // `if` however unreachable one of them is. This is the one place the
    // fourth backend would fail to compile if the guard were ordinary.
    if (comptime be_platform) |platform| {
        assert(
            @src(),
            vocab.flagCount(platform) == be.values.len,
            "the two halves of the flag table disagree about its length",
        );
    }
}

// ==========================================================================
// Shared decoding
// ==========================================================================

/// The dirname/basename split that inotify and kqueue both make on a path with
/// no name of its own.
///
/// The two backends agree on the split and disagree on what a path with no
/// separator in it means, so both answers to that are parameters: inotify
/// reports the whole path as the directory and no file at all, and kqueue
/// reports `.` as the directory and the whole path as the file. Everything
/// else -- including scanning from the terminating zero rather than from the
/// last byte, which is why a path ending in `/` splits on that one -- is
/// shared, and was written out twice in C.
fn splitPath(
    kvs: [*c]c.JanetKV,
    path: c.Janet,
    no_sep_dir: c.Janet,
    no_sep_file: c.Janet,
) void {
    const spath = c.janet_unwrap_string(path);
    const len = c.janet_string_length(spath);
    var cursor: i32 = len;
    while (cursor > 0 and spath[@intCast(cursor)] != '/') cursor -= 1;
    if (cursor == 0) {
        c.janet_struct_put(kvs, c.janet_ckeywordv("dir-name"), no_sep_dir);
        c.janet_struct_put(kvs, c.janet_ckeywordv("file-name"), no_sep_file);
    } else {
        c.janet_struct_put(kvs, c.janet_ckeywordv("dir-name"), c.janet_wrap_string(c.janet_string(spath, cursor)));
        c.janet_struct_put(kvs, c.janet_ckeywordv("file-name"), c.janet_wrap_string(c.janet_string(spath + @as(usize, @intCast(cursor)) + 1, len - cursor - 1)));
    }
}

// ==========================================================================
// The abstract type
// ==========================================================================

/// `janet_filewatch_mark`.
fn filewatchMark(p: ?*anyopaque, s: usize) callconv(.c) c_int {
    _ = s;
    const watcher = watcherOf(p);
    if (watcher.channel == null) return 0; // Incomplete initialization
    be.mark(watcher);
    c.janet_mark(c.janet_wrap_abstract(watcher.channel));
    c.janet_mark(c.janet_wrap_table(watcher.watch_descriptors));
    return 0;
}

/// `janet_filewatch_at`. `JANET_ATEND_GCMARK` leaves every field after
/// `gcmark` null, which the translated structure already defaults them to.
///
/// `pub` for `test/filewatch_core.zig`, which asks the mirror rather than the
/// `JanetAbstractType` behind `janet_abstract_type`: every field after
/// `gcmark` being null is what makes a watcher opaque, and the mirror is where
/// that is written.
pub const janet_filewatch_at: abstract_type.AbstractType = .{
    .name = "filewatch/watcher",
    .gc = null,
    .gcmark = &filewatchMark,
};

// ==========================================================================
// The cfunctions
// ==========================================================================

fn makeImpl(argc: i32, argv: [*c]c.Janet) raise.Raising(c.Janet) {
    try lifecycle.sandboxAssert(c.JANET_SANDBOX_FS_READ);
    try arglayer.arity(argc, 1, -1);
    const channel = try evloop.getChannel(argv, 0);
    const watcher = watcherOf(c.janet_abstract(abstract_type.stored(&janet_filewatch_at), @sizeOf(JanetWatcher)));
    const default_flags = try be.decode(argv + 1, argc - 1);
    try be.init(watcher, channel, default_flags);
    return c.janet_wrap_abstract(watcher);
}

fn addImpl(argc: i32, argv: [*c]c.Janet) raise.Raising(c.Janet) {
    try arglayer.arity(argc, 2, -1);
    const watcher = watcherOf(try arglayer.getAbstract(argv, 0, abstract_type.stored(&janet_filewatch_at)));
    const path = try arglayer.getCString(argv, 1);
    const flags = watcher.default_flags | try be.decode(argv + 2, argc - 2);
    try be.add(watcher, path, flags);
    return argv[0];
}

fn removeImpl(argc: i32, argv: [*c]c.Janet) raise.Raising(c.Janet) {
    try arglayer.fixarity(argc, 2);
    const watcher = watcherOf(try arglayer.getAbstract(argv, 0, abstract_type.stored(&janet_filewatch_at)));
    // TODO - pass string in directly to avoid extra allocation
    const path = try arglayer.getCString(argv, 1);
    try be.remove(watcher, path);
    return argv[0];
}

fn listenImpl(argc: i32, argv: [*c]c.Janet) raise.Raising(c.Janet) {
    try arglayer.fixarity(argc, 1);
    const watcher = watcherOf(try arglayer.getAbstract(argv, 0, abstract_type.stored(&janet_filewatch_at)));
    try be.listen(watcher);
    return c.janet_wrap_nil();
}

fn unlistenImpl(argc: i32, argv: [*c]c.Janet) raise.Raising(c.Janet) {
    try arglayer.fixarity(argc, 1);
    const watcher = watcherOf(try arglayer.getAbstract(argv, 0, abstract_type.stored(&janet_filewatch_at)));
    try be.unlisten(watcher);
    return c.janet_wrap_nil();
}

// ==========================================================================
// Registration
// ==========================================================================

/// `janet_lib_filewatch`. The order is the C original's exactly.
export fn janet_lib_filewatch(env: *c.JanetTable) callconv(.c) void {
    assertTableIsWhole();
    const table = comptime [_]corefn.Entry{
        corefn.reg("filewatch/new", &makeImpl, @src(), "(filewatch/new channel & default-flags)", "Create a new filewatcher that will give events to a channel channel. See `filewatch/add` for available flags.\n\n" ++
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
        corefn.reg("filewatch/add", &addImpl, @src(), "(filewatch/add watcher path flag & more-flags)", "Add a path to the watcher. Available flags depend on the current OS, and are as follows:\n\n" ++
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
        corefn.reg("filewatch/remove", &removeImpl, @src(), "(filewatch/remove watcher path)", "Remove a path from the watcher."),
        corefn.reg("filewatch/listen", &listenImpl, @src(), "(filewatch/listen watcher)", "Listen for changes in the watcher."),
        corefn.reg("filewatch/unlisten", &unlistenImpl, @src(), "(filewatch/unlisten watcher)", "Stop listening for changes on a given watcher."),
        corefn.end,
    };
    corefn.install(env, &table);
}
