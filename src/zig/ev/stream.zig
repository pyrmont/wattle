//! `core/stream`: the wrapper around a pollable file descriptor or handle, the
//! read and write state machines every asynchronous transfer runs through, the
//! pipe constructor, and the five stream cfunctions. Part of the `-Dev-loop`
//! object; `ev_loop.zig` has the reasoning for why the four files are one
//! module.
//!
//! Two host structures are named here and neither is reached by translation.
//! `JanetOverlapped` lives in `src/core/util.h`, which no translation ever
//! carried, so its Windows body is restated in Zig over
//! `std.os.windows.OVERLAPPED`; the C original spells it as a union of
//! `OVERLAPPED` and `WSAOVERLAPPED`, and those two have the same layout, so
//! one member is enough and the union is not reproduced. The socket calls take
//! `struct sockaddr *`, which crosses as an opaque pointer over a byte buffer
//! exactly as `ev.c` treats it -- `janet_address_type`'s abstract carries the
//! bytes and nothing here reads a field.

const std = @import("std");
const builtin = @import("builtin");
const corefn = @import("corefn");
const raise = @import("raise");
const pp_format = @import("../pp/format.zig");
const ev = @import("../ev.zig");
const backend = @import("backend.zig");

const types = @import("types");
const repr = @import("repr");
const constants = @import("constants");
const c = @import("cabi");
const vm_lifecycle = @import("../vm/lifecycle.zig");
const buffers = @import("../value/buffers.zig");
const marsh = @import("../marsh.zig");
const abstract_type = @import("../abstract_type.zig");
const method_type = @import("../method_type.zig");
const ev_callback = @import("../callback_type.zig");
const strings = @import("../value/strings.zig");
const utils = @import("../utils.zig");
const gc_mark = @import("../gc/mark.zig");
const io_core = @import("../io.zig");
/// The `recvfrom` arm's address abstract. **Reached by import rather than by
/// symbol**: an `@export` of an `AbstractType` is not legal once that struct
/// stops being `extern`, which a slice field forces. Both uses sit under
/// `if (has_net and ...)`, and `has_net` is comptime, so a build without the
/// net subsystem never analyses the branch that names this.
const net = @import("../net.zig");
const wrap = @import("../value/helpers/wrap.zig");
const args_core = @import("../args.zig");
const abstracts = @import("../value/abstracts.zig");
const value = @import("../value.zig");
const windows = ev.windows;
const has_net = ev.has_net;

/// `OVERLAPPED` and `WSAOVERLAPPED`, which Zig 0.16's `std.os.windows` no
/// longer declares. The two have the same layout, and the real `OVERLAPPED`
/// spells its middle eight bytes as a union of `{ Offset, OffsetHigh }` and a
/// `Pointer`; only the first arm is ever used here, so it is written flat.
pub const OVERLAPPED = extern struct {
    Internal: usize,
    InternalHigh: usize,
    Offset: u32,
    OffsetHigh: u32,
    hEvent: ?*anyopaque,
};

/// `WSABUF`, for the same reason.
const WSABUF = extern struct {
    len: u32,
    buf: [*]u8,
};

/// `JANET_EV_CHUNKSIZE`, which `ev.c` defines only on Windows because only the
/// completion-port arm copies through a fixed buffer.
const chunk_size_windows: i32 = 4096;

/// `JanetOverlapped` from `src/core/util.h`. See the file comment.
pub const Overlapped = extern struct {
    as: OVERLAPPED,
    bytes_transfered: u32,
};

const stream_closed: u32 = @intCast(constants.JANET_STREAM_CLOSED);
const stream_socket: u32 = @intCast(constants.JANET_STREAM_SOCKET);
const stream_unregistered: u32 = @intCast(constants.JANET_STREAM_UNREGISTERED);
const stream_readable: u32 = @intCast(constants.JANET_STREAM_READABLE);
const stream_writable: u32 = @intCast(constants.JANET_STREAM_WRITABLE);
const stream_acceptable: u32 = @intCast(constants.JANET_STREAM_ACCEPTABLE);
const stream_udpserver: u32 = @intCast(constants.JANET_STREAM_UDPSERVER);
const stream_not_closeable: u32 = @intCast(constants.JANET_STREAM_NOT_CLOSEABLE);
const stream_toclose: u32 = @intCast(constants.JANET_STREAM_TOCLOSE);
const stream_nodups: u32 = @intCast(constants.JANET_STREAM_NODUPS);

/// `INVALID_HANDLE_VALUE`, and the closed marker on POSIX. `JanetHandle` is
/// `void *` on Windows and `int` elsewhere, which a translation got wrong for
/// the mingw targets; `types.zig` carries the corrected declaration.
inline fn invalidHandle() types.JanetHandle {
    return if (windows) @ptrFromInt(std.math.maxInt(usize)) else -1;
}

// ==========================================================================
// The host calls
// ==========================================================================

extern fn recv(fd: c_int, buf: [*]u8, len: usize, flags: c_int) callconv(.c) isize;
extern fn recvfrom(fd: c_int, buf: [*]u8, len: usize, flags: c_int, from: ?*anyopaque, fromlen: *c_uint) callconv(.c) isize;
extern fn send(fd: c_int, buf: [*]const u8, len: usize, flags: c_int) callconv(.c) isize;
extern fn sendto(fd: c_int, buf: [*]const u8, len: usize, flags: c_int, to: ?*const anyopaque, tolen: c_uint) callconv(.c) isize;

const F_SETFD: c_int = 2;
const F_SETFL: c_int = 4;
const FD_CLOEXEC: c_int = 1;
const O_NONBLOCK: c_int = if (builtin.os.tag == .linux) 0o4000 else 0x0004;

extern "kernel32" fn GetLastError() callconv(.winapi) u32;
extern "kernel32" fn FormatMessageA(flags: u32, source: ?*const anyopaque, id: u32, lang: u32, buf: [*]u8, size: u32, args: ?*anyopaque) callconv(.winapi) u32;
extern "kernel32" fn ReadFile(h: ?*anyopaque, buf: [*]u8, count: u32, read_out: ?*u32, ov: ?*OVERLAPPED) callconv(.winapi) c_int;
extern "kernel32" fn WriteFile(h: ?*anyopaque, buf: [*]const u8, count: u32, written: ?*u32, ov: ?*OVERLAPPED) callconv(.winapi) c_int;
extern "kernel32" fn DuplicateHandle(src_proc: ?*anyopaque, src: ?*anyopaque, dst_proc: ?*anyopaque, dst: *?*anyopaque, access: u32, inherit: c_int, options: u32) callconv(.winapi) c_int;
extern "kernel32" fn GetCurrentProcess() callconv(.winapi) ?*anyopaque;
extern "kernel32" fn GetCurrentProcessId() callconv(.winapi) u32;
extern "kernel32" fn CreatePipe(read: *?*anyopaque, write: *?*anyopaque, attrs: ?*SecurityAttributes, size: u32) callconv(.winapi) c_int;
extern "kernel32" fn CreateNamedPipeA(name: [*:0]const u8, open_mode: u32, pipe_mode: u32, max_instances: u32, out_size: u32, in_size: u32, timeout: u32, attrs: ?*SecurityAttributes) callconv(.winapi) ?*anyopaque;
extern "kernel32" fn CreateFileA(name: [*:0]const u8, access: u32, share: u32, attrs: ?*SecurityAttributes, disposition: u32, flags: u32, template: ?*anyopaque) callconv(.winapi) ?*anyopaque;
extern "ws2_32" fn closesocket(s: usize) callconv(.winapi) c_int;
extern "ws2_32" fn WSAGetLastError() callconv(.winapi) c_int;
extern "ws2_32" fn WSARecvFrom(s: usize, bufs: [*]WSABUF, count: u32, received: ?*u32, flags: *u32, from: ?*anyopaque, fromlen: ?*i32, ov: ?*OVERLAPPED, routine: ?*anyopaque) callconv(.winapi) c_int;
extern "ws2_32" fn WSASendTo(s: usize, bufs: [*]WSABUF, count: u32, sent: ?*u32, flags: u32, to: ?*const anyopaque, tolen: c_int, ov: ?*OVERLAPPED, routine: ?*anyopaque) callconv(.winapi) c_int;
extern fn _open_osfhandle(h: isize, flags: c_int) callconv(.c) c_int;
extern fn _dup(fd: c_int) callconv(.c) c_int;
extern fn _close(fd: c_int) callconv(.c) c_int;
extern fn _fdopen(fd: c_int, mode: [*:0]const u8) callconv(.c) ?*anyopaque;

const SecurityAttributes = extern struct {
    nLength: u32,
    lpSecurityDescriptor: ?*anyopaque,
    bInheritHandle: c_int,
};

const FORMAT_MESSAGE_FROM_SYSTEM: u32 = 0x1000;
const FORMAT_MESSAGE_IGNORE_INSERTS: u32 = 0x200;
const ERROR_IO_PENDING: u32 = 997;
const ERROR_BROKEN_PIPE: u32 = 109;
const WSA_IO_PENDING: c_int = 997;
const MAX_PATH: usize = 260;
const PIPE_ACCESS_INBOUND: u32 = 0x1;
const PIPE_ACCESS_OUTBOUND: u32 = 0x2;
const FILE_FLAG_OVERLAPPED: u32 = 0x40000000;
const PIPE_TYPE_BYTE: u32 = 0x0;
const PIPE_WAIT: u32 = 0x0;
const GENERIC_READ: u32 = 0x80000000;
const GENERIC_WRITE: u32 = 0x40000000;
const OPEN_EXISTING: u32 = 3;
const FILE_ATTRIBUTE_NORMAL: u32 = 0x80;
const DUPLICATE_SAME_ACCESS: u32 = 0x2;
const O_RDONLY: c_int = 0;
const O_WRONLY: c_int = 1;
const O_RDWR: c_int = 2;

/// The pipe name counter `janet_make_pipe` uses on Windows.
///
/// The C original reaches it with `InterlockedIncrement`, which mingw supplies
/// as a compiler intrinsic rather than as a symbol its import library
/// exports -- so a Zig `extern` declaration of it links on no target at all.
/// `@atomicRmw` is the same operation, and `InterlockedIncrement` reports the
/// *incremented* value, which is why the addend is added back here.
var pipe_serial_number: i32 = 0;

inline fn nextPipeSerial() u32 {
    return @bitCast(@atomicRmw(i32, &pipe_serial_number, .Add, 1, .seq_cst) +% 1);
}

// ==========================================================================
// Errors
// ==========================================================================

/// The last host error, as a Janet string.
pub fn evLasterr() repr.Value {
    if (windows) {
        const code = GetLastError();
        var msgbuf: [256]u8 = undefined;
        msgbuf[0] = 0;
        _ = FormatMessageA(
            FORMAT_MESSAGE_FROM_SYSTEM | FORMAT_MESSAGE_IGNORE_INSERTS,
            null,
            code,
            0, // MAKELANGID(LANG_NEUTRAL, SUBLANG_DEFAULT)
            &msgbuf,
            msgbuf.len,
            null,
        );
        if (msgbuf[0] == 0) {
            _ = std.fmt.bufPrintZ(&msgbuf, "{d}", .{code}) catch {};
        }
        // The message ends in CRLF; keep only the first line.
        var i: usize = 0;
        while (msgbuf[i] != 0) : (i += 1) {
            if (msgbuf[i] == '\n' or msgbuf[i] == '\r') {
                msgbuf[i] = 0;
                break;
            }
        }
        return value.fromBytes(std.mem.sliceTo(&msgbuf, 0), .string);
    }
    return value.fromBytes(std.mem.span(utils.strerrorSafe(ev.errno())), .string);
}

// ==========================================================================
// The stream abstract type
// ==========================================================================

const default_methods = [_]method_type.Method{
    .{ .name = "close", .cfun = &cfunStreamClose },
    .{ .name = "read", .cfun = &cfunStreamRead },
    .{ .name = "chunk", .cfun = &cfunStreamChunk },
    .{ .name = "write", .cfun = &cfunStreamWrite },
    .{ .name = null, .cfun = null },
};

/// Build a stream over `handle` and register it with the backend.
///
/// `registerStream` raises when the backend refuses the descriptor -- a failed
/// `epoll_ctl` or `kevent` -- so this is raise-capable and every caller inside
/// the runtime reaches it rather than `janet_stream_ext`. Reaching the abi
/// instead turns that raise into a report nobody consumes.
pub fn makeStreamExt(
    handle: types.JanetHandle,
    flags: u32,
    methods: ?[*]const types.JanetMethod,
    size: usize,
) raise.Raising(*types.JanetStream) {
    ev.assert(@src(), size >= @sizeOf(types.JanetStream), "bad size");
    const s: *types.JanetStream = @ptrCast(@alignCast(abstracts.new(&streamType, size)));
    s.handle = handle;
    s.flags = flags;
    s.read_fiber = null;
    s.write_fiber = null;
    s.methods = methods orelse &default_methods;
    s.index = 0;
    try backend.registerStream(s);
    return s;
}

pub fn streamExt(
    handle: types.JanetHandle,
    flags: u32,
    methods: ?[*]const types.JanetMethod,
    size: usize,
) callconv(.c) *types.JanetStream {
    return raise.reported(makeStreamExt(handle, flags, methods, size));
}

/// The same at the default size, which is what every caller in the tree wants.
pub fn makeStream(
    handle: types.JanetHandle,
    flags: u32,
    methods: ?[*]const types.JanetMethod,
) raise.Raising(*types.JanetStream) {
    return makeStreamExt(handle, flags, methods, @sizeOf(types.JanetStream));
}

pub fn makeStreamAbi(handle: types.JanetHandle, flags: u32, methods: ?[*]const types.JanetMethod) *types.JanetStream {
    return raise.reported(makeStream(handle, flags, methods));
}

/// Close the underlying handle, unregistering it first where the backend
/// needs that. The `NODUPS` optimization is what lets the unregister be
/// skipped: a stream nothing has duplicated is the last reference to its file
/// description, and closing it removes it from the poll set for free.
fn closeImplHandle(s: *types.JanetStream) raise.Raising(void) {
    s.flags |= stream_closed;
    const canclose = s.flags & stream_not_closeable == 0;
    if (windows) {
        if (s.handle != invalidHandle()) {
            if (has_net and (s.flags & stream_socket != 0)) {
                if (canclose) _ = closesocket(@intFromPtr(s.handle));
            } else {
                if (canclose) _ = ev.CloseHandle(s.handle);
            }
            s.handle = invalidHandle();
        }
    } else {
        const canunregister = s.flags & stream_unregistered == 0;
        if (s.handle != -1) {
            if (canunregister) try backend.unregisterStream(s);
            if (canclose) _ = ev.close(s.handle);
            s.handle = -1;
        }
    }
}

pub fn streamClose(s: *types.JanetStream) raise.Raising(void) {
    const rf = s.read_fiber;
    const wf = s.write_fiber;
    if (rf != null and rf.?.ev_callback != null) {
        try ev_callback.of(rf.?.ev_callback)(rf.?, constants.JANET_ASYNC_EVENT_CLOSE);
        s.read_fiber = null;
    }
    if (wf != null and wf.?.ev_callback != null) {
        try ev_callback.of(wf.?.ev_callback)(wf.?, constants.JANET_ASYNC_EVENT_CLOSE);
        s.write_fiber = null;
    }
    try closeImplHandle(s);
}

pub fn streamCloseAbi(s: *types.JanetStream) void {
    raise.reported(streamClose(s));
}

/// Close a stream that was marked `TOCLOSE` once nothing is listening on it.
pub fn checkToClose(s: *types.JanetStream) raise.Raising(void) {
    if ((s.flags & stream_toclose != 0) and s.read_fiber == null and s.write_fiber == null) {
        try streamClose(s);
    }
}

/// The collector finalizing a stream: close the handle and let it go.
///
/// `closeImplHandle` raises when the backend refuses to unregister the
/// descriptor -- a failed `epoll_ctl` or `kevent`. This is the one `gc` in the
/// tree that could, and it is discarded here rather than reported, because
/// there is nobody to report it to: the stream is already unreachable, the
/// handle is being closed either way, and no caller can retry a close. The
/// file comment on `abstract_type.AbstractType` has the contract.
fn streamGC(stream: *types.JanetStream, _: usize) c_int {
    closeImplHandle(stream) catch {};
    return 0;
}

fn streamMark(stream: *types.JanetStream, _: usize) c_int {
    if (stream.read_fiber) |rf| gc_mark.mark(wrap.fromFiber(rf));
    if (stream.write_fiber) |wf| gc_mark.mark(wrap.fromFiber(wf));
    return 0;
}

fn streamGetter(stream: *types.JanetStream, key: repr.Value, out: *repr.Value) raise.Raising(c_int) {
    if (!repr.checkType(key, repr.Tag.keyword)) return 0;
    return args_core.getmethod(wrap.toKeyword(key), @ptrCast(@alignCast(stream.methods)), out);
}

fn streamMarshal(s: *types.JanetStream, ctx: *types.JanetMarshalContext) raise.Raising(void) {
    if (marsh.marshalFlags(ctx) & constants.JANET_MARSHAL_UNSAFE == 0) {
        return raise.panic("can only marshal stream with unsafe flag");
    }
    // This stream might now be duplicated, which invalidates some EV
    // optimizations.
    s.flags &= ~stream_nodups;
    marsh.marshalAbstract(ctx, s);
    try marsh.marshalInt(ctx, @bitCast(s.flags));
    try marsh.marshalPtr(ctx, s.methods);
    if (windows) {
        // The C original's TODO stands: there is no reference counting to stop
        // a handle being closed or collected in transit, and `DuplicateHandle`
        // does not work for sockets.
        var duph: ?*anyopaque = invalidHandle();
        if (s.flags & stream_socket != 0) {
            duph = s.handle;
        } else {
            _ = DuplicateHandle(
                GetCurrentProcess(),
                s.handle,
                GetCurrentProcess(),
                &duph,
                0,
                0,
                DUPLICATE_SAME_ACCESS,
            );
        }
        try marsh.marshalInt64(ctx, @bitCast(@intFromPtr(duph)));
    } else {
        // Marshal after dup because it is easier than maintaining our own
        // reference counting.
        const duph = ev.dup(s.handle);
        if (duph < 0) return pp_format.panicf("failed to duplicate stream handle: %V", .{evLasterr()});
        try marsh.marshalInt(ctx, duph);
    }
}

fn streamUnmarshal(ctx: *types.JanetMarshalContext) raise.Raising(*types.JanetStream) {
    if (marsh.unmarshalFlags(ctx) & constants.JANET_MARSHAL_UNSAFE == 0) {
        return raise.panic("can only unmarshal stream with unsafe flag");
    }
    const p: *types.JanetStream = @ptrCast(@alignCast(try marsh.unmarshalAbstract(ctx, @sizeOf(types.JanetStream))));
    // Listening state cannot be shared across threads.
    p.read_fiber = null;
    p.write_fiber = null;
    p.flags = @bitCast(try marsh.unmarshalInt(ctx));
    p.methods = try marsh.unmarshalPtr(ctx);
    if (windows) {
        p.handle = @ptrFromInt(@as(usize, @bitCast(try marsh.unmarshalInt64(ctx))));
    } else {
        p.handle = try marsh.unmarshalInt(ctx);
    }
    // Only the poll backend keeps its own table of streams, so only it has to
    // be told about one that arrived by unmarshalling.
    if (backend.selected == .poll) try backend.registerStream(p);
    return p;
}

fn streamNext(stream: *types.JanetStream, key: repr.Value) raise.Raising(repr.Value) {
    return args_core.nextmethod(@ptrCast(@alignCast(stream.methods)), key);
}

/// `[fd=N]`, so that a user can print the descriptor when debugging.
///
/// Janet hands `janet_formatb` a `JanetHandle` for a `%d`, which pulls an
/// `int32_t`. That is exact away from Windows and a mismatched vararg width
/// there, which is undefined, so this truncates explicitly rather than
/// reproducing it. `FOUND.md` has the entry.
fn streamToString(stream: *types.JanetStream, buffer: *types.JanetBuffer) raise.Raising(void) {
    const shown: i32 = if (windows) @truncate(@as(isize, @bitCast(@intFromPtr(stream.handle)))) else stream.handle;
    _ = try pp_format.formatb(buffer, "[fd=%d]", .{shown});
}

/// `pub` for the three subsystems that used to declare it `extern const` --
/// `ev.zig`, `net/abi.zig` and `net.zig` -- and for `test/ev_loop.zig`, which
/// calls the raising callbacks directly.
pub const streamType = abstract_type.define(types.JanetStream, .{
    .name = "core/stream",
    .gc = streamGC,
    .gcmark = streamMark,
    .get = streamGetter,
    .marshal = streamMarshal,
    .unmarshal = streamUnmarshal,
    .tostring = streamToString,
    .next = streamNext,
});

/// Check that a stream is open and has every capability the caller needs.
pub fn streamFlags(s: *types.JanetStream, flags: u32) raise.Raising(void) {
    if (s.flags & stream_closed != 0) return raise.panic("stream is closed");
    if ((s.flags & flags) != flags) {
        const rmsg = if (flags & stream_readable != 0) "readable " else "";
        const wmsg = if (flags & stream_writable != 0) "writable " else "";
        const amsg = if (flags & stream_acceptable != 0) "server " else "";
        const dmsg = if (flags & stream_udpserver != 0) "datagram " else "";
        const smsg = if (flags & stream_socket != 0) "socket" else "stream";
        return pp_format.panicf(
            "bad stream, expected %s%s%s%s%s",
            .{ rmsg.ptr, wmsg.ptr, amsg.ptr, dmsg.ptr, smsg.ptr },
        );
    }
}

pub fn streamFlagsAbi(s: *types.JanetStream, flags: u32) void {
    raise.reported(streamFlags(s, flags));
}

// ==========================================================================
// The read state machine
// ==========================================================================

pub const read_mode_read: c_int = 0;
pub const read_mode_recv: c_int = 1;
pub const read_mode_recvfrom: c_int = 2;

const StateRead = extern struct {
    overlapped: if (windows) Overlapped else void align(if (windows) @alignOf(Overlapped) else 1),
    flags: if (windows) u32 else c_int,
    wbuf: if (windows and has_net) WSABUF else void,
    from: if (windows and has_net) [128]u8 else void,
    fromlen: if (windows and has_net) i32 else void,
    chunk_buf: if (windows) [chunk_size_windows]u8 else void,
    bytes_left: i32,
    bytes_read: i32,
    buf: *types.JanetBuffer,
    is_chunk: c_int,
    mode: c_int,
};

fn ev_callback_read(fiber: *types.JanetFiber, event: types.JanetAsyncEvent) raise.Raising(void) {
    const s: *types.JanetStream = fiber.*.ev_stream.?;
    const state: *StateRead = @ptrCast(@alignCast(fiber.*.ev_state));
    switch (event) {
        constants.JANET_ASYNC_EVENT_MARK => gc_mark.mark(wrap.fromBuffer(state.buf)),
        constants.JANET_ASYNC_EVENT_CLOSE => {
            ev.schedule(fiber, wrap.fromNil());
            ev.asyncEnd(fiber);
        },
        else => {
            if (windows) {
                try readWindows(fiber, s, state, event);
            } else {
                try readPosix(fiber, s, state, event);
            }
        },
    }
}

fn readWindows(fiber: *types.JanetFiber, s: *types.JanetStream, state: *StateRead, event: types.JanetAsyncEvent) raise.Raising(void) {
    var start_transfer = false;
    switch (event) {
        constants.JANET_ASYNC_EVENT_FAILED, constants.JANET_ASYNC_EVENT_COMPLETE => {
            // Called when the read finished.
            const ev_bytes: u32 = @truncate(state.overlapped.bytes_transfered);
            state.bytes_read += @intCast(ev_bytes);
            if (state.bytes_read == 0 and state.mode != read_mode_recvfrom) {
                ev.schedule(fiber, wrap.fromNil());
                ev.asyncEnd(fiber);
                return;
            }
            _ = try buffers.pushBytes(state.buf, state.chunk_buf[0..@intCast(ev_bytes)]);
            state.bytes_left -= @intCast(ev_bytes);
            if (state.bytes_left == 0 or state.is_chunk == 0 or ev_bytes == 0) {
                var resume_val: repr.Value = undefined;
                if (has_net and state.mode == read_mode_recvfrom) {
                    const abst = abstracts.new(&net.addressType, @intCast(state.fromlen));
                    @memcpy(@as([*]u8, @ptrCast(abst))[0..@intCast(state.fromlen)], state.from[0..@intCast(state.fromlen)]);
                    resume_val = wrap.fromAbstract(abst);
                } else {
                    resume_val = wrap.fromBuffer(state.buf);
                }
                ev.schedule(fiber, resume_val);
                ev.asyncEnd(fiber);
                return;
            }
            start_transfer = true;
        },
        constants.JANET_ASYNC_EVENT_INIT => start_transfer = true,
        else => {},
    }
    if (!start_transfer) return;

    const chunk = if (state.bytes_left > chunk_size_windows) chunk_size_windows else state.bytes_left;
    state.overlapped = std.mem.zeroes(Overlapped);
    if (has_net and state.mode == read_mode_recvfrom) {
        state.wbuf.len = @intCast(chunk);
        state.wbuf.buf = &state.chunk_buf;
        state.fromlen = @intCast(state.from.len);
        const status = WSARecvFrom(
            @intFromPtr(s.handle),
            @ptrCast(&state.wbuf),
            1,
            null,
            &state.flags,
            &state.from,
            &state.fromlen,
            &state.overlapped.as,
            null,
        );
        if (status != 0 and WSAGetLastError() != WSA_IO_PENDING) {
            try ev.cancel(fiber, evLasterr());
            ev.asyncEnd(fiber);
            return;
        }
    } else {
        // Some handles (not all) read from the offset in lpOverlapped; if it
        // is not set before calling ReadFile those streams always read from
        // offset 0.
        state.overlapped.as.Offset = @bitCast(state.bytes_read);
        const status = ReadFile(s.handle, &state.chunk_buf, @intCast(chunk), null, &state.overlapped.as);
        if (status == 0 and GetLastError() != ERROR_IO_PENDING) {
            if (GetLastError() == ERROR_BROKEN_PIPE) {
                if (state.bytes_read != 0) {
                    ev.schedule(fiber, wrap.fromBuffer(state.buf));
                } else {
                    ev.schedule(fiber, wrap.fromNil());
                }
            } else {
                try ev.cancel(fiber, evLasterr());
            }
            ev.asyncEnd(fiber);
            return;
        }
    }
    ev.asyncInFlight(fiber);
}

fn readPosix(fiber: *types.JanetFiber, s: *types.JanetStream, state: *StateRead, event: types.JanetAsyncEvent) raise.Raising(void) {
    switch (event) {
        constants.JANET_ASYNC_EVENT_ERR => {
            if (state.bytes_read != 0) {
                ev.schedule(fiber, wrap.fromBuffer(state.buf));
            } else {
                ev.schedule(fiber, wrap.fromNil());
            }
            s.read_fiber = null;
            ev.asyncEnd(fiber);
        },
        constants.JANET_ASYNC_EVENT_HUP, constants.JANET_ASYNC_EVENT_INIT, constants.JANET_ASYNC_EVENT_READ => {
            // The C original's `read_more` label, which the tail of this body
            // jumps back to when a chunked read has more to collect.
            while (true) {
                const buffer = state.buf;
                var bytes_left = state.bytes_left;
                const read_limit: i32 = if (state.is_chunk != 0)
                    (if (bytes_left > 4096) 4096 else bytes_left)
                else
                    bytes_left;
                try buffers.extra(buffer, read_limit);
                var nread: isize = undefined;
                var saddr: [256]u8 = undefined;
                var socklen: c_uint = @intCast(saddr.len);
                while (true) {
                    const dest = buffer.*.data.? + @as(usize, @intCast(buffer.*.count));
                    if (has_net and state.mode == read_mode_recvfrom) {
                        nread = recvfrom(s.handle, dest, @intCast(read_limit), state.flags, &saddr, &socklen);
                    } else if (has_net and state.mode == read_mode_recv) {
                        nread = recv(s.handle, dest, @intCast(read_limit), state.flags);
                    } else {
                        nread = ev.read(s.handle, dest, @intCast(read_limit));
                    }
                    if (!(nread == -1 and ev.errno() == ev.EINTR)) break;
                }

                // Check for errors, special-casing the ones that can be fixed
                // by waiting.
                if (nread == -1) {
                    if (ev.errno() == ev.EAGAIN or ev.errno() == ev.EWOULDBLOCK) return;
                    // In stream protocols, a pipe error is end of stream.
                    if (ev.errno() == ev.EPIPE and state.mode != read_mode_recvfrom) {
                        nread = 0;
                    } else {
                        try ev.cancel(fiber, evLasterr());
                        ev.asyncEnd(fiber);
                        return;
                    }
                }

                // Only allow zero-length packets in recvfrom; in a stream
                // protocol a zero-length packet is end of stream.
                state.bytes_read += @intCast(nread);
                if (state.bytes_read == 0 and state.mode != read_mode_recvfrom) {
                    ev.schedule(fiber, wrap.fromNil());
                    ev.asyncEnd(fiber);
                    return;
                }

                buffer.*.count += @intCast(nread);
                bytes_left -= @intCast(nread);
                state.bytes_left = bytes_left;

                if (state.is_chunk == 0 or bytes_left == 0 or nread == 0) {
                    var resume_val: repr.Value = undefined;
                    if (has_net and state.mode == read_mode_recvfrom) {
                        const abst = abstracts.new(&net.addressType, socklen);
                        @memcpy(@as([*]u8, @ptrCast(abst))[0..socklen], saddr[0..socklen]);
                        resume_val = wrap.fromAbstract(abst);
                    } else {
                        resume_val = wrap.fromBuffer(buffer);
                    }
                    ev.schedule(fiber, resume_val);
                    ev.asyncEnd(fiber);
                    return;
                }
                // Read some more if possible.
            }
        },
        else => {},
    }
}

pub fn readGeneric(
    s: *types.JanetStream,
    buf: *types.JanetBuffer,
    nbytes: i32,
    is_chunked: bool,
    mode: c_int,
    flags: c_int,
) raise.Error {
    const state: *StateRead = @ptrCast(@alignCast(utils.malloc(@sizeOf(StateRead)) orelse
        ev.outOfMemory(@src())));
    state.is_chunk = @intFromBool(is_chunked);
    state.buf = buf;
    state.bytes_left = nbytes;
    state.bytes_read = 0;
    state.mode = mode;
    state.flags = if (windows) @bitCast(flags) else flags;
    return ev.asyncStart(s, constants.JANET_ASYNC_LISTEN_READ, ev_callback_read, state);
}

pub fn evRead(s: *types.JanetStream, buf: *types.JanetBuffer, nbytes: i32) void {
    raise.report(readGeneric(s, buf, nbytes, false, read_mode_read, 0));
}

pub fn evReadchunk(s: *types.JanetStream, buf: *types.JanetBuffer, nbytes: i32) void {
    raise.report(readGeneric(s, buf, nbytes, true, read_mode_read, 0));
}

comptime {
    if (has_net) {}
}

pub fn evRecv(s: *types.JanetStream, buf: *types.JanetBuffer, nbytes: i32, flags: c_int) void {
    raise.report(readGeneric(s, buf, nbytes, false, read_mode_recv, flags));
}

pub fn evRecvChunk(s: *types.JanetStream, buf: *types.JanetBuffer, nbytes: i32, flags: c_int) void {
    raise.report(readGeneric(s, buf, nbytes, true, read_mode_recv, flags));
}

pub fn evRecvFrom(s: *types.JanetStream, buf: *types.JanetBuffer, nbytes: i32, flags: c_int) void {
    raise.report(readGeneric(s, buf, nbytes, false, read_mode_recvfrom, flags));
}

// ==========================================================================
// The write state machine
// ==========================================================================

pub const write_mode_write: c_int = 0;
pub const write_mode_send: c_int = 1;
pub const write_mode_sendto: c_int = 2;

const StateWrite = extern struct {
    overlapped: if (windows) Overlapped else void align(if (windows) @alignOf(Overlapped) else 1),
    flags: if (windows) u32 else c_int,
    wbuf: if (windows and has_net) WSABUF else void,
    start: if (windows) void else i32,
    src: extern union {
        buf: *types.JanetBuffer,
        str: [*:0]const u8,
    },
    is_buffer: c_int,
    mode: c_int,
    dest_abst: ?*anyopaque,
};

fn ev_callback_write(fiber: *types.JanetFiber, event: types.JanetAsyncEvent) raise.Raising(void) {
    const s: *types.JanetStream = fiber.*.ev_stream.?;
    const state: *StateWrite = @ptrCast(@alignCast(fiber.*.ev_state));
    switch (event) {
        constants.JANET_ASYNC_EVENT_MARK => {
            gc_mark.mark(if (state.is_buffer != 0)
                wrap.fromBuffer(state.src.buf)
            else
                wrap.fromString(state.src.str));
            if (state.mode == write_mode_sendto) {
                gc_mark.mark(wrap.fromAbstract(state.dest_abst));
            }
        },
        constants.JANET_ASYNC_EVENT_CLOSE => {
            try ev.cancel(fiber, value.fromBytes("stream closed", .string));
            ev.asyncEnd(fiber);
        },
        else => {
            if (windows) {
                try writeWindows(fiber, s, state, event);
            } else {
                try writePosix(fiber, s, state, event);
            }
        },
    }
}

fn writeWindows(fiber: *types.JanetFiber, s: *types.JanetStream, state: *StateWrite, event: types.JanetAsyncEvent) raise.Raising(void) {
    switch (event) {
        constants.JANET_ASYNC_EVENT_FAILED, constants.JANET_ASYNC_EVENT_COMPLETE => {
            const ev_bytes: u32 = @truncate(state.overlapped.bytes_transfered);
            if (ev_bytes == 0 and state.mode != write_mode_sendto) {
                try ev.cancel(fiber, value.fromBytes("disconnect", .string));
                ev.asyncEnd(fiber);
                return;
            }
            ev.schedule(fiber, wrap.fromNil());
            ev.asyncEnd(fiber);
        },
        constants.JANET_ASYNC_EVENT_INIT => {
            var len: i32 = undefined;
            var bytes: [*]const u8 = undefined;
            if (state.is_buffer != 0) {
                // If a buffer, convert to a string. The C original's TODO
                // asking to be more efficient about this stands.
                const buffer = state.src.buf;
                const str = strings.new(buffer.*.slice());
                bytes = str;
                len = buffer.*.count;
                state.is_buffer = 0;
                state.src.str = str;
            } else {
                bytes = state.src.str;
                len = types.stringHead(bytes).length;
            }
            state.overlapped = std.mem.zeroes(Overlapped);

            if (has_net and state.mode == write_mode_sendto) {
                state.wbuf.buf = @constCast(bytes);
                state.wbuf.len = @intCast(len);
                const to = state.dest_abst;
                const tolen: c_int = @intCast(types.abstractHead(to).size);
                const status = WSASendTo(
                    @intFromPtr(s.handle),
                    @ptrCast(&state.wbuf),
                    1,
                    null,
                    state.flags,
                    to,
                    tolen,
                    &state.overlapped.as,
                    null,
                );
                if (status != 0) {
                    if (WSAGetLastError() == WSA_IO_PENDING) {
                        ev.asyncInFlight(fiber);
                    } else {
                        try ev.cancel(fiber, evLasterr());
                        ev.asyncEnd(fiber);
                        return;
                    }
                }
            } else {
                // File handles in IOCP need this to write to the end of a
                // file. Where the underlying resource cannot seek, the byte
                // offsets are ignored.
                state.overlapped.as.Offset = 0xFFFFFFFF;
                state.overlapped.as.OffsetHigh = 0xFFFFFFFF;
                const status = WriteFile(s.handle, bytes, @intCast(len), null, &state.overlapped.as);
                if (status == 0) {
                    if (GetLastError() == ERROR_IO_PENDING) {
                        ev.asyncInFlight(fiber);
                    } else {
                        try ev.cancel(fiber, evLasterr());
                        ev.asyncEnd(fiber);
                        return;
                    }
                }
            }
        },
        else => {},
    }
}

fn writePosix(fiber: *types.JanetFiber, s: *types.JanetStream, state: *StateWrite, event: types.JanetAsyncEvent) raise.Raising(void) {
    switch (event) {
        constants.JANET_ASYNC_EVENT_ERR => {
            try ev.cancel(fiber, value.fromBytes("stream err", .string));
            ev.asyncEnd(fiber);
        },
        constants.JANET_ASYNC_EVENT_HUP => {
            try ev.cancel(fiber, value.fromBytes("stream hup", .string));
            ev.asyncEnd(fiber);
        },
        constants.JANET_ASYNC_EVENT_INIT, constants.JANET_ASYNC_EVENT_WRITE => {
            var len: i32 = undefined;
            var bytes: [*]const u8 = undefined;
            var start = state.start;
            if (state.is_buffer != 0) {
                const buffer = state.src.buf;
                bytes = buffer.*.data.?;
                len = buffer.*.count;
            } else {
                bytes = state.src.str;
                len = types.stringHead(bytes).length;
            }
            var nwrote: isize = 0;
            if (start < len) {
                const nbytes = len - start;
                const dest_abst = state.dest_abst;
                while (true) {
                    const from = bytes + @as(usize, @intCast(start));
                    if (has_net and state.mode == write_mode_sendto) {
                        nwrote = sendto(s.handle, from, @intCast(nbytes), state.flags, dest_abst, @intCast(types.abstractHead(dest_abst).size));
                    } else if (has_net and state.mode == write_mode_send) {
                        nwrote = send(s.handle, from, @intCast(nbytes), state.flags);
                    } else {
                        nwrote = ev.write(s.handle, from, @intCast(nbytes));
                    }
                    if (!(nwrote == -1 and ev.errno() == ev.EINTR)) break;
                }

                if (nwrote == -1) {
                    if (ev.errno() == ev.EAGAIN or ev.errno() == ev.EWOULDBLOCK) return;
                    try ev.cancel(fiber, evLasterr());
                    ev.asyncEnd(fiber);
                    return;
                }

                // Unless using datagrams, an empty message is a disconnect.
                if (nwrote == 0 and dest_abst == null) {
                    try ev.cancel(fiber, value.fromBytes("disconnect", .string));
                    ev.asyncEnd(fiber);
                    return;
                }

                if (nwrote > 0) {
                    start += @intCast(nwrote);
                } else {
                    start = len;
                }
            }
            state.start = start;
            if (start >= len) {
                ev.schedule(fiber, wrap.fromNil());
                ev.asyncEnd(fiber);
            }
        },
        else => {},
    }
}

pub fn writeGeneric(
    s: *types.JanetStream,
    buf: ?*anyopaque,
    dest_abst: ?*anyopaque,
    mode: c_int,
    is_buffer: bool,
    flags: c_int,
) raise.Error {
    const state: *StateWrite = @ptrCast(@alignCast(utils.malloc(@sizeOf(StateWrite)) orelse
        ev.outOfMemory(@src())));
    state.is_buffer = @intFromBool(is_buffer);
    state.src.buf = @ptrCast(@alignCast(buf));
    state.dest_abst = dest_abst;
    state.mode = mode;
    state.flags = if (windows) @bitCast(flags) else flags;
    if (!windows) state.start = 0;
    return ev.asyncStart(s, constants.JANET_ASYNC_LISTEN_WRITE, ev_callback_write, state);
}

pub fn evWriteBuffer(s: *types.JanetStream, buf: *types.JanetBuffer) void {
    raise.report(writeGeneric(s, buf, null, write_mode_write, true, 0));
}

pub fn evWriteString(s: *types.JanetStream, str: [*:0]const u8) void {
    raise.report(writeGeneric(s, @constCast(str), null, write_mode_write, false, 0));
}

pub fn evSendBuffer(s: *types.JanetStream, buf: *types.JanetBuffer, flags: c_int) void {
    raise.report(writeGeneric(s, buf, null, write_mode_send, true, flags));
}

pub fn evSendString(s: *types.JanetStream, str: [*:0]const u8, flags: c_int) void {
    raise.report(writeGeneric(s, @constCast(str), null, write_mode_send, false, flags));
}

pub fn evSendToBuffer(s: *types.JanetStream, buf: *types.JanetBuffer, dest: ?*anyopaque, flags: c_int) void {
    raise.report(writeGeneric(s, buf, dest, write_mode_sendto, true, flags));
}

pub fn evSendToString(s: *types.JanetStream, str: [*:0]const u8, dest: ?*anyopaque, flags: c_int) void {
    raise.report(writeGeneric(s, @constCast(str), dest, write_mode_sendto, false, flags));
}

// ==========================================================================
// Pipes
// ==========================================================================

/// Create a pipe, reporting 0 on success and -1 on failure.
///
/// mode 0: both sides non-blocking.
/// mode 1: only the read side non-blocking; the write side goes to a subprocess.
/// mode 2: only the write side non-blocking; the read side goes to a subprocess.
/// mode 3: both sides blocking, for a pipeline between two external processes.
/// Reached by import. It was `export fn janet_make_pipe`, declared again as an
/// `extern fn` by two other Zig files -- three Zig files calling each other
/// through the symbol table. Nothing outside the runtime ever called it, so
/// the symbol went with the seam.
pub fn makePipe(handles: *[2]types.JanetHandle, mode: c_int) c_int {
    if (windows) {
        // The built-in CreatePipe does not support overlapped IO, so this
        // lifts the Windows source and modifies it, exactly as `ev.c` does.
        var sa_attr = std.mem.zeroes(SecurityAttributes);
        sa_attr.nLength = @sizeOf(SecurityAttributes);
        sa_attr.bInheritHandle = 1;
        if (mode == 3) {
            // No overlapped IO involved, so just call CreatePipe.
            var rd: ?*anyopaque = undefined;
            var wr: ?*anyopaque = undefined;
            if (CreatePipe(&rd, &wr, &sa_attr, 0) == 0) return -1;
            handles[0] = rd;
            handles[1] = wr;
            return 0;
        }
        var name_buf: [MAX_PATH]u8 = undefined;
        const name = std.fmt.bufPrintZ(&name_buf, "\\\\.\\Pipe\\JanetPipeFile.{x:0>8}.{x:0>8}", .{
            GetCurrentProcessId(),
            nextPipeSerial(),
        }) catch return -1;

        // The server handle goes to the subprocess.
        const shandle = CreateNamedPipeA(
            name.ptr,
            (if (mode == 2) PIPE_ACCESS_INBOUND else PIPE_ACCESS_OUTBOUND) | FILE_FLAG_OVERLAPPED,
            PIPE_TYPE_BYTE | PIPE_WAIT,
            255, // Max number of pipes for duplication.
            4096, // Out buffer size.
            4096, // In buffer size.
            120 * 1000, // Timeout in ms.
            &sa_attr,
        );
        if (shandle == invalidHandle()) return -1;

        // We keep the client handle.
        const chandle = CreateFileA(
            name.ptr,
            if (mode == 2) GENERIC_WRITE else GENERIC_READ,
            0,
            &sa_attr,
            OPEN_EXISTING,
            FILE_ATTRIBUTE_NORMAL | FILE_FLAG_OVERLAPPED,
            null,
        );
        if (chandle == invalidHandle()) {
            _ = ev.CloseHandle(shandle);
            return -1;
        }
        if (mode == 2) {
            handles[0] = shandle;
            handles[1] = chandle;
        } else {
            handles[0] = chandle;
            handles[1] = shandle;
        }
        return 0;
    }

    if (ev.pipe(handles) != 0) return -1;
    const ok = (mode == 2 or ev.fcntl(handles[0], F_SETFD, FD_CLOEXEC) == 0) and
        (mode == 1 or ev.fcntl(handles[1], F_SETFD, FD_CLOEXEC) == 0) and
        (mode == 2 or mode == 3 or ev.fcntl(handles[0], F_SETFL, O_NONBLOCK) == 0) and
        (mode == 1 or mode == 3 or ev.fcntl(handles[1], F_SETFL, O_NONBLOCK) == 0);
    if (ok) return 0;
    _ = ev.close(handles[0]);
    _ = ev.close(handles[1]);
    return -1;
}

// ==========================================================================
// The cfunctions
// ==========================================================================

fn getStream(argv: []const repr.Value, n: i32) raise.Raising(*types.JanetStream) {
    return @ptrCast(@alignCast(try args_core.getAbstract(argv, n, &streamType)));
}

pub fn cfunStreamClose(argv: []repr.Value) align(corefn.alignment) raise.Raising(repr.Value) {
    try args_core.fixarity(argv, 1);
    try streamClose(try getStream(argv, 0));
    return argv[0];
}

pub fn cfunStreamRead(argv: []repr.Value) align(corefn.alignment) raise.Raising(repr.Value) {
    try args_core.arity(argv, 2, 4);
    const s = try getStream(argv, 0);
    try streamFlags(s, stream_readable);
    const buffer = try args_core.optBuffer(argv, 2, 10);
    const to = try args_core.optNumber(argv, 3, std.math.inf(f64));
    if (args_core.keyeq(argv[1], "all") != 0) {
        if (to != std.math.inf(f64)) ev.addtimeout(to);
        return readGeneric(s, buffer, std.math.maxInt(i32), true, read_mode_read, 0);
    }
    const n = try args_core.getNat(argv, 1);
    if (to != std.math.inf(f64)) ev.addtimeout(to);
    return readGeneric(s, buffer, n, false, read_mode_read, 0);
}

pub fn cfunStreamChunk(argv: []repr.Value) align(corefn.alignment) raise.Raising(repr.Value) {
    try args_core.arity(argv, 2, 4);
    const s = try getStream(argv, 0);
    try streamFlags(s, stream_readable);
    const n = try args_core.getNat(argv, 1);
    const buffer = try args_core.optBuffer(argv, 2, 10);
    const to = try args_core.optNumber(argv, 3, std.math.inf(f64));
    if (to != std.math.inf(f64)) ev.addtimeout(to);
    return readGeneric(s, buffer, n, true, read_mode_read, 0);
}

pub fn cfunStreamWrite(argv: []repr.Value) align(corefn.alignment) raise.Raising(repr.Value) {
    try args_core.arity(argv, 2, 3);
    const s = try getStream(argv, 0);
    try streamFlags(s, stream_writable);
    const to = try args_core.optNumber(argv, 2, std.math.inf(f64));
    if (repr.checkType(argv[1], repr.Tag.buffer)) {
        if (to != std.math.inf(f64)) ev.addtimeout(to);
        return writeGeneric(s, try args_core.getBuffer(argv, 1), null, write_mode_write, true, 0);
    }
    const bytes = try args_core.getBytes(argv, 1);
    if (to != std.math.inf(f64)) ev.addtimeout(to);
    return writeGeneric(s, @constCast(bytes.bytes), null, write_mode_write, false, 0);
}

/// A blocking `core/file` over the same descriptor, for code that cannot wait
/// on the event loop. The handle is duplicated, so the two are independent.
fn getFileForStream(s: *types.JanetStream) raise.Raising(?*types.JanetFile) {
    var flags: i32 = 0;
    var fmt = [_]u8{ 0, 0, 0, 0 };
    var index: usize = 0;
    if (s.flags & stream_readable != 0) {
        flags |= constants.JANET_FILE_READ;
        try vm_lifecycle.sandboxAssert(types.Sandbox.of(&.{"fs_read"}));
        fmt[index] = 'r';
        index += 1;
    }
    if (s.flags & stream_writable != 0) {
        flags |= constants.JANET_FILE_WRITE;
        try vm_lifecycle.sandboxAssert(types.Sandbox.of(&.{"fs_write"}));
        fmt[index] = if (index == 0) 'w' else '+';
        index += 1;
    }
    if (index == 0) return null;
    // Duplicate the handle when converting a stream to a file.
    s.flags &= ~stream_nodups;
    var f: ?*anyopaque = null;
    if (windows) {
        var htype: c_int = 0;
        if (fmt[0] == 'r' and fmt[1] == '+') {
            htype = O_RDWR;
        } else if (fmt[0] == 'r') {
            htype = O_RDONLY;
        } else if (fmt[0] == 'w') {
            htype = O_WRONLY;
        }
        const fd = _open_osfhandle(@bitCast(@intFromPtr(s.handle)), htype);
        if (fd < 0) return null;
        const fd_dup = _dup(fd);
        if (fd_dup < 0) return null;
        f = _fdopen(fd_dup, @ptrCast(&fmt));
        if (f == null) {
            _ = _close(fd_dup);
            return null;
        }
    } else {
        const fd_dup = ev.dup(s.handle);
        if (fd_dup < 0) return null;
        f = ev.fdopen(fd_dup, @ptrCast(&fmt));
        if (f == null) {
            _ = ev.close(fd_dup);
            return null;
        }
    }
    return io_core.makejfile(@ptrCast(@alignCast(f)), flags);
}

fn cfunToFile(argv: []repr.Value) raise.Raising(repr.Value) {
    try args_core.fixarity(argv, 1);
    const s = try getStream(argv, 0);
    const iof = try getFileForStream(s);
    if (iof == null) return raise.panic("cannot make file from stream");
    return wrap.fromAbstract(iof);
}

/// The four stream rows of `janet_lib_ev`, in its order.
pub fn entries() []const corefn.Entry {
    const list = comptime blk: {
        var acc: []const corefn.Entry = &.{};
        acc = acc ++ [_]corefn.Entry{
            corefn.reg("ev/close", &cfunStreamClose, @src(), "(ev/close stream)", "Close a stream. This should be the same as calling (:close stream) for all streams."),
            corefn.reg("ev/read", &cfunStreamRead, @src(), "(ev/read stream n &opt buffer timeout)", "Read up to n bytes into a buffer asynchronously from a stream. `n` can also be the keyword " ++
                "`:all` to read into the buffer until end of stream. " ++
                "Optionally provide a buffer to write into " ++
                "as well as a timeout in seconds after which to cancel the operation and raise an error. " ++
                "Returns the buffer if the read was successful or nil if end-of-stream reached. Will raise an " ++
                "error if there are problems with the IO operation."),
            corefn.reg("ev/chunk", &cfunStreamChunk, @src(), "(ev/chunk stream n &opt buffer timeout)", "Same as ev/read, but will not return early if less than n bytes are available. If an end of " ++
                "stream is reached, will also return early with the collected bytes."),
            corefn.reg("ev/write", &cfunStreamWrite, @src(), "(ev/write stream data &opt timeout)", "Write data to a stream, suspending the current fiber until the write " ++
                "completes. Takes an optional timeout in seconds, after which will return nil. " ++
                "Returns nil, or raises an error if the write failed."),
        };
        break :blk acc;
    };
    return list;
}

/// `ev/to-file`, which `janet_lib_ev` registers after the lock rows.
pub fn toFileEntries() []const corefn.Entry {
    const list = comptime blk: {
        var acc: []const corefn.Entry = &.{};
        acc = acc ++ [_]corefn.Entry{
            corefn.reg("ev/to-file", &cfunToFile, @src(), "(ev/to-file)", "Create core/file copy of the stream. This value can be used " ++
                "when blocking IO behavior is needed."),
        };
        break :blk acc;
    };
    return list;
}
