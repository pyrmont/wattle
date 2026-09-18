//! `core/stream`: the wrapper around a pollable file descriptor or handle, the
//! read and write state machines every asynchronous transfer runs through, the
//! pipe constructor, and the five stream cfunctions.
//!
//! Two host structures are named here and neither comes from a system header.
//! `Overlapped` is restated below, because `WSAOVERLAPPED` and `OVERLAPPED`
//! have the same layout and one member is enough. And the socket calls take a
//! `struct sockaddr *`, which crosses as an opaque pointer over a byte buffer:
//! the address abstract has the bytes and nothing here reads a field.

// ==========================================================================
// Standard library imports
// ==========================================================================

const std = @import("std");
const builtin = @import("builtin");

// ==========================================================================
// Project imports
// ==========================================================================

const abi = @import("abi");
const abstract_type = @import("../../api/abstract_type.zig");
const abstracts = @import("../value/abstracts.zig");
const args_core = @import("../args.zig");
const backend = @import("backend.zig");
const buffers = @import("../value/buffers.zig");
const c = @import("cabi");
const constants = @import("constants");
const corefn = @import("../corefn.zig");
const ev = @import("../ev.zig");
const ev_callback = @import("../callback_type.zig");
const fibers = @import("../value/fibers.zig");
const gc_mark = @import("../gc/mark.zig");
const host = @import("host");
const io_core = @import("../io.zig");
const marsh = @import("../marsh.zig");
const method_type = @import("../method_type.zig");

/// The `c.recvfrom` arm's address abstract, reached by import rather than by
/// symbol: an `@export` of an `AbstractType` is not legal once that struct
/// stops being `extern`, which a slice field forces. Both uses sit under
/// `if (has_net and ...)`, and `has_net` is comptime, so a build without the
/// net subsystem never analyses the branch that names this.
const net = @import("../net.zig");
const pp_format = @import("../pp/format.zig");
const raise = @import("../../api/raise.zig");
const repr = @import("repr");
const strings = @import("../value/strings.zig");
const utils = @import("../utils.zig");
const value = @import("../value.zig");
const vm_lifecycle = @import("../vm/lifecycle.zig");
const wrap = @import("../value/helpers/wrap.zig");

// ==========================================================================
// Constants
// ==========================================================================

/// The Win32 constants the completion-port arm and the named-pipe constructor
/// name, each written out rather than translated.
const DUPLICATE_SAME_ACCESS: u32 = 0x2;
const ERROR_BROKEN_PIPE: u32 = 109;
const ERROR_IO_PENDING: u32 = 997;
const FILE_ATTRIBUTE_NORMAL: u32 = 0x80;
const FILE_FLAG_OVERLAPPED: u32 = 0x40000000;
const FORMAT_MESSAGE_FROM_SYSTEM: u32 = 0x1000;
const FORMAT_MESSAGE_IGNORE_INSERTS: u32 = 0x200;
const GENERIC_READ: u32 = 0x80000000;
const GENERIC_WRITE: u32 = 0x40000000;
const MAX_PATH: usize = 260;
const OPEN_EXISTING: u32 = 3;
const PIPE_ACCESS_INBOUND: u32 = 0x1;
const PIPE_ACCESS_OUTBOUND: u32 = 0x2;
const PIPE_TYPE_BYTE: u32 = 0x0;
const PIPE_WAIT: u32 = 0x0;
const WSA_IO_PENDING: c_int = 997;

/// The POSIX descriptor flags, which are the same numbers on every target this
/// project builds for.
const FD_CLOEXEC: c_int = 1;
const F_SETFD: c_int = 2;
const F_SETFL: c_int = 4;
const O_NONBLOCK: c_int = if (builtin.os.tag == .linux) 0o4000 else 0x0004;
const O_RDONLY: c_int = 0;
const O_RDWR: c_int = 2;
const O_WRONLY: c_int = 1;

/// The fixed buffer an asynchronous transfer copies through. Windows only:
/// only the completion-port arm copies.
const chunk_size_windows: i32 = 4096;

/// The methods every stream has, which the abstract type's `get` looks in.
const default_methods = [_]method_type.Method{
    .{ .name = "close", .cfun = &cfunStreamClose },
    .{ .name = "read", .cfun = &cfunStreamRead },
    .{ .name = "chunk", .cfun = &cfunStreamChunk },
    .{ .name = "write", .cfun = &cfunStreamWrite },
    .{ .name = null, .cfun = null },
};

/// Whether this build has the net subsystem, which decides whether the
/// address abstract above is ever named.
const has_net = ev.has_net;

/// The pipe name counter `makePipe` uses on Windows.
///
/// `InterlockedIncrement` is the Win32 spelling, and mingw supplies it as a
/// compiler intrinsic rather than as a symbol its import library exports, so a
/// Zig `extern` declaration of it links on no target at all. `@atomicRmw` is
/// the same operation; it reports the value before the increment where
/// `InterlockedIncrement` reports the one after, and the addend is added back
/// here for that reason.
var pipe_serial_number: i32 = 0;

/// Which of the three read calls a transfer makes: `read`, `recv` or
/// `recvfrom`.
pub const read_mode_read: c_int = 0;
pub const read_mode_recv: c_int = 1;
pub const read_mode_recvfrom: c_int = 2;

/// The abstract type a stream is.
///
/// `pub` for the three subsystems that reach it by import, `ev.zig`,
/// `net/abi.zig` and `net.zig`, and for `test/ev_loop.zig`, which calls the
/// raising callbacks directly.
pub const streamType = abstract_type.define(Stream, .{
    .name = "core/stream",
    .gc = streamGC,
    .gcmark = streamMark,
    .get = streamGetter,
    .marshal = streamMarshal,
    .unmarshal = streamUnmarshal,
    .tostring = streamToString,
    .next = streamNext,
});

/// The stream flag word: what the stream is, what it can do, and what has
/// happened to it.
const stream_acceptable: u32 = @intCast(constants.stream_acceptable);
const stream_closed: u32 = @intCast(constants.stream_closed);
const stream_nodups: u32 = @intCast(constants.stream_nodups);
const stream_not_closeable: u32 = @intCast(constants.stream_not_closeable);
const stream_readable: u32 = @intCast(constants.stream_readable);
const stream_socket: u32 = @intCast(constants.stream_socket);
const stream_toclose: u32 = @intCast(constants.stream_toclose);
const stream_udpserver: u32 = @intCast(constants.stream_udpserver);
const stream_unregistered: u32 = @intCast(constants.stream_unregistered);
const stream_writable: u32 = @intCast(constants.stream_writable);

/// Whether this target takes the completion-port arm of every transfer below.
const windows = ev.windows;

/// Which of the three write calls a transfer makes: `write`, `send` or
/// `sendto`.
pub const write_mode_send: c_int = 1;
pub const write_mode_sendto: c_int = 2;
pub const write_mode_write: c_int = 0;

// ==========================================================================
// Types
// ==========================================================================

/// An `OVERLAPPED` with the transfer count beside it. The head of this file
/// says why it is restated rather than translated.
pub const Overlapped = extern struct {
    as: c.OVERLAPPED,
    bytes_transfered: u32,
};

/// What a read in progress needs to resume: the mode, the destination, and how
/// many bytes are still outstanding.
const StateRead = struct {
    overlapped: if (windows) Overlapped else void align(if (windows) @alignOf(Overlapped) else 1),
    flags: if (windows) u32 else c_int,
    wbuf: if (windows and has_net) c.WSABUF else void,
    from: if (windows and has_net) [128]u8 else void,
    fromlen: if (windows and has_net) i32 else void,
    chunk_buf: if (windows) [chunk_size_windows]u8 else void,
    bytes_left: i32,
    bytes_read: i32,
    buf: *buffers.Buffer,
    is_chunk: c_int,
    mode: c_int,
};

/// What a write in progress needs to resume: the mode, the source, and how far
/// it has got.
const StateWrite = struct {
    overlapped: if (windows) Overlapped else void align(if (windows) @alignOf(Overlapped) else 1),
    flags: if (windows) u32 else c_int,
    wbuf: if (windows and has_net) c.WSABUF else void,
    start: if (windows) void else i32,
    src: extern union {
        buf: *buffers.Buffer,
        str: [*:0]const u8,
    },
    is_buffer: c_int,
    mode: c_int,
    dest_abst: ?*anyopaque,
};

/// A `core/stream`: the handle, the flag word, the two waiting fibers and the
/// backend's own bookkeeping.
///
/// `extern` is earned: `makeStreamExt` allocates `@sizeOf(Stream)` plus a
/// caller's payload and hands back the header, so the payload sits at a fixed
/// offset that both sides compute independently. `test/ev_loop.zig`'s
/// `ProbeStream` is the other side.
pub const Stream = extern struct {
    handle: host.Handle = std.mem.zeroes(host.Handle),
    flags: u32 = 0,
    index: u32 = 0,
    read_fiber: ?*fibers.Fiber = null,
    write_fiber: ?*fibers.Fiber = null,
    methods: ?*const anyopaque = null,
};

// ==========================================================================
// Public functions
// ==========================================================================

/// `(ev/chunk s n &opt buf)`.
pub fn cfunStreamChunk(argv: []repr.Value) raise.Error!repr.Value {
    try args_core.arity(argv, 2, 4);
    const s = try getStream(argv, 0);
    try streamFlags(s, stream_readable);
    const n = try args_core.getNat(argv, 1);
    const buffer = try args_core.optBuffer(argv, 2, 10);
    const to = try args_core.optNumber(argv, 3, std.math.inf(f64));
    if (to != std.math.inf(f64)) ev.addtimeout(to);
    return readGeneric(s, buffer, n, true, read_mode_read, 0);
}

/// `(:close s)`.
pub fn cfunStreamClose(argv: []repr.Value) raise.Error!repr.Value {
    try args_core.fixarity(argv, 1);
    try streamClose(try getStream(argv, 0));
    return argv[0];
}

/// `(ev/read s n &opt buf timeout)`.
pub fn cfunStreamRead(argv: []repr.Value) raise.Error!repr.Value {
    try args_core.arity(argv, 2, 4);
    const s = try getStream(argv, 0);
    try streamFlags(s, stream_readable);
    const buffer = try args_core.optBuffer(argv, 2, 10);
    const to = try args_core.optNumber(argv, 3, std.math.inf(f64));
    if (args_core.keyeq(argv[1], "all")) {
        if (to != std.math.inf(f64)) ev.addtimeout(to);
        return readGeneric(s, buffer, std.math.maxInt(i32), true, read_mode_read, 0);
    }
    const n = try args_core.getNat(argv, 1);
    if (to != std.math.inf(f64)) ev.addtimeout(to);
    return readGeneric(s, buffer, n, false, read_mode_read, 0);
}

/// `(ev/write s bytes &opt timeout)`.
pub fn cfunStreamWrite(argv: []repr.Value) raise.Error!repr.Value {
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

/// Closes a stream marked `constants.stream_toclose`, once nothing is
/// listening on it.
pub fn checkToClose(s: *Stream) raise.Error!void {
    if ((s.flags & stream_toclose != 0) and s.read_fiber == null and s.write_fiber == null) {
        try streamClose(s);
    }
}

/// The four stream rows `ev.zig`'s `libEv` installs, in its order.
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

/// The last host error, as a Janet string.
pub fn evLasterr() repr.Value {
    if (windows) {
        const code = c.GetLastError();
        var msgbuf: [256]u8 = undefined;
        msgbuf[0] = 0;
        _ = c.FormatMessageA(
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
    return value.fromBytes(std.mem.span(utils.strerrorSafe(c.errno())), .string);
}

/// Creates a pipe, reporting 0 on success and -1 on failure.
///
/// Mode 0 makes both sides non-blocking; mode 1 only the read side, with the
/// write side going to a subprocess; mode 2 only the write side; and mode 3
/// neither, for a pipeline between two external processes.
///
/// Reached by import: nothing outside the runtime calls it, so it is not a
/// symbol.
pub fn makePipe(handles: *[2]host.Handle, mode: c_int) c_int {
    if (windows) {
        // The built-in CreatePipe does not support overlapped IO, so this
        // lifts the Windows source and modifies it, exactly as `ev.c` does.
        var sa_attr = std.mem.zeroes(c.SecurityAttributes);
        sa_attr.nLength = @sizeOf(c.SecurityAttributes);
        sa_attr.bInheritHandle = 1;
        if (mode == 3) {
            // No overlapped IO involved, so just call CreatePipe.
            var rd: ?*anyopaque = undefined;
            var wr: ?*anyopaque = undefined;
            if (c.CreatePipe(&rd, &wr, &sa_attr, 0) == 0) return -1;
            handles[0] = rd;
            handles[1] = wr;
            return 0;
        }
        var name_buf: [MAX_PATH]u8 = undefined;
        const name = std.fmt.bufPrintZ(&name_buf, "\\\\.\\Pipe\\WattlePipeFile.{x:0>8}.{x:0>8}", .{
            c.GetCurrentProcessId(),
            nextPipeSerial(),
        }) catch return -1;

        // The server handle goes to the subprocess.
        const shandle = c.CreateNamedPipeA(
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
        const chandle = c.CreateFileA(
            name.ptr,
            if (mode == 2) GENERIC_WRITE else GENERIC_READ,
            0,
            &sa_attr,
            OPEN_EXISTING,
            FILE_ATTRIBUTE_NORMAL | FILE_FLAG_OVERLAPPED,
            null,
        );
        if (chandle == invalidHandle()) {
            _ = c.CloseHandle(shandle);
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

    if (c.pipe(handles) != 0) return -1;
    const ok = (mode == 2 or c.fcntl(handles[0], F_SETFD, FD_CLOEXEC) == 0) and
        (mode == 1 or c.fcntl(handles[1], F_SETFD, FD_CLOEXEC) == 0) and
        (mode == 2 or mode == 3 or c.fcntl(handles[0], F_SETFL, O_NONBLOCK) == 0) and
        (mode == 1 or mode == 3 or c.fcntl(handles[1], F_SETFL, O_NONBLOCK) == 0);
    if (ok) return 0;
    _ = c.close(handles[0]);
    _ = c.close(handles[1]);
    return -1;
}

/// `makeStreamExt` at the default size, which is what every caller in the tree
/// asks for.
pub fn makeStream(
    handle: host.Handle,
    flags: u32,
    methods: ?[*]const method_type.CMethod,
) raise.Error!*Stream {
    return makeStreamExt(handle, flags, methods, @sizeOf(Stream));
}

/// Builds a stream over `handle` and registers it with the backend.
///
/// `registerStream` raises when the backend refuses the descriptor, a failed
/// `epoll_ctl` or `kevent`, so this is raise-capable, and every caller in the
/// runtime reaches it by import and `try`s it. A reporting form would turn
/// that raise into a report nobody consumes.
pub fn makeStreamExt(
    handle: host.Handle,
    flags: u32,
    methods: ?[*]const method_type.CMethod,
    size: usize,
) raise.Error!*Stream {
    ev.assert(@src(), size >= @sizeOf(Stream), "bad size");
    const s: *Stream = @ptrCast(@alignCast(abstracts.newBytes(&streamType, size)));
    s.handle = handle;
    s.flags = flags;
    s.read_fiber = null;
    s.write_fiber = null;
    s.methods = methods orelse &default_methods;
    s.index = 0;
    try backend.registerStream(s);
    return s;
}

/// The read state machine, over whichever of the three calls the mode names.
pub fn readGeneric(
    s: *Stream,
    buf: *buffers.Buffer,
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
    return ev.asyncStart(s, constants.AsyncMode.reading, ev_callback_read, state);
}

/// Closes a stream from Janet, which is what `(:close s)` reaches.
pub fn streamClose(s: *Stream) raise.Error!void {
    const rf = s.read_fiber;
    const wf = s.write_fiber;
    if (rf) |f| {
        if (f.ev_callback != null) {
            try ev_callback.of(f.ev_callback)(f, constants.AsyncEvent.close);
            s.read_fiber = null;
        }
    }
    if (wf) |f| {
        if (f.ev_callback != null) {
            try ev_callback.of(f.ev_callback)(f, constants.AsyncEvent.close);
            s.write_fiber = null;
        }
    }
    try closeImplHandle(s);
}

/// Checks that a stream is open and has every capability the caller needs.
pub fn streamFlags(s: *Stream, flags: u32) raise.Error!void {
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

/// `ev/to-file`, which `ev.zig`'s `libEv` registers after the lock rows.
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

// The host calls this file makes directly. Each names a type this file
// declares, so it stays with the type rather than moving to `cabi.zig`.

/// The write state machine, over whichever of the three calls the mode names.
pub fn writeGeneric(
    s: *Stream,
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
    return ev.asyncStart(s, constants.AsyncMode.writing, ev_callback_write, state);
}

// ==========================================================================
// Private functions
// ==========================================================================

/// `(ev/to-file s)`.
fn cfunToFile(argv: []repr.Value) raise.Error!repr.Value {
    try args_core.fixarity(argv, 1);
    const s = try getStream(argv, 0);
    const iof = (try getFileForStream(s)) orelse return raise.panic("cannot make file from stream");
    return wrap.fromAbstract(iof);
}

/// Closes the underlying handle, unregistering it first where the backend
/// needs that. The `NODUPS` optimisation is what lets the unregister be
/// skipped: a stream nothing has duplicated is the last reference to its file
/// description, and closing it removes it from the poll set for free.
fn closeImplHandle(s: *Stream) raise.Error!void {
    s.flags |= stream_closed;
    const canclose = s.flags & stream_not_closeable == 0;
    if (windows) {
        if (s.handle != invalidHandle()) {
            if (has_net and (s.flags & stream_socket != 0)) {
                if (canclose) _ = c.closesocket(@intFromPtr(s.handle));
            } else {
                if (canclose) _ = c.CloseHandle(s.handle);
            }
            s.handle = invalidHandle();
        }
    } else {
        const canunregister = s.flags & stream_unregistered == 0;
        if (s.handle != -1) {
            if (canunregister) try backend.unregisterStream(s);
            if (canclose) _ = c.close(s.handle);
            s.handle = -1;
        }
    }
}

/// What the loop calls when a stream a read is waiting on becomes ready.
fn ev_callback_read(fiber: *fibers.Fiber, event: ev.AsyncEvent) raise.Error!void {
    const s: *Stream = fiber.ev_stream.?;
    const state: *StateRead = @ptrCast(@alignCast(fiber.ev_state));
    switch (event) {
        constants.AsyncEvent.mark => gc_mark.mark(wrap.fromBuffer(state.buf)),
        constants.AsyncEvent.close => {
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

/// What the loop calls when a stream a write is waiting on becomes ready.
fn ev_callback_write(fiber: *fibers.Fiber, event: ev.AsyncEvent) raise.Error!void {
    const s: *Stream = fiber.ev_stream.?;
    const state: *StateWrite = @ptrCast(@alignCast(fiber.ev_state));
    switch (event) {
        constants.AsyncEvent.mark => {
            gc_mark.mark(if (state.is_buffer != 0)
                wrap.fromBuffer(state.src.buf)
            else
                wrap.fromString(state.src.str));
            if (state.mode == write_mode_sendto) {
                gc_mark.mark(wrap.fromAbstract(state.dest_abst.?));
            }
        },
        constants.AsyncEvent.close => {
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

/// A blocking `core/file` over the same descriptor, for code that cannot wait
/// on the event loop. The handle is duplicated, so the two are independent.
fn getFileForStream(s: *Stream) raise.Error!?*io_core.File {
    var flags: i32 = 0;
    var fmt = [_]u8{ 0, 0, 0, 0 };
    var index: usize = 0;
    if (s.flags & stream_readable != 0) {
        flags |= constants.file_read;
        try vm_lifecycle.sandboxAssert(vm_lifecycle.Sandbox.of(&.{"fs_read"}));
        fmt[index] = 'r';
        index += 1;
    }
    if (s.flags & stream_writable != 0) {
        flags |= constants.file_write;
        try vm_lifecycle.sandboxAssert(vm_lifecycle.Sandbox.of(&.{"fs_write"}));
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
        const fd = c._open_osfhandle(@bitCast(@intFromPtr(s.handle)), htype);
        if (fd < 0) return null;
        const fd_dup = c._dup(fd);
        if (fd_dup < 0) return null;
        f = c._fdopen(fd_dup, @ptrCast(&fmt));
        if (f == null) {
            _ = c._close(fd_dup);
            return null;
        }
    } else {
        const fd_dup = c.dup(s.handle);
        if (fd_dup < 0) return null;
        f = c.fdopen(fd_dup, @ptrCast(&fmt));
        if (f == null) {
            _ = c.close(fd_dup);
            return null;
        }
    }
    return io_core.makejfile(@ptrCast(@alignCast(f)), flags);
}

/// The stream argument at `argv[n]`, or a raise where it is not a stream.
fn getStream(argv: []const repr.Value, n: usize) raise.Error!*Stream {
    return try args_core.getAbstract(Stream, argv, n, &streamType);
}

/// `INVALID_HANDLE_VALUE`, and the closed marker on POSIX. `host.Handle` is
/// `void *` on Windows and `int` elsewhere, which a translation got wrong for
/// the mingw targets; `host.zig` has the corrected declaration beside the
/// other shapes the host decides.
inline fn invalidHandle() host.Handle {
    return if (windows) @ptrFromInt(std.math.maxInt(usize)) else -1;
}

/// The next Windows pipe name, which has to be unique in the process.
inline fn nextPipeSerial() u32 {
    return @bitCast(@atomicRmw(i32, &pipe_serial_number, .Add, 1, .seq_cst) +% 1);
}

/// The POSIX read, straight into the caller's buffer.
fn readPosix(fiber: *fibers.Fiber, s: *Stream, state: *StateRead, event: ev.AsyncEvent) raise.Error!void {
    switch (event) {
        constants.AsyncEvent.err => {
            if (state.bytes_read != 0) {
                ev.schedule(fiber, wrap.fromBuffer(state.buf));
            } else {
                ev.schedule(fiber, wrap.fromNil());
            }
            s.read_fiber = null;
            ev.asyncEnd(fiber);
        },
        constants.AsyncEvent.hup, constants.AsyncEvent.init, constants.AsyncEvent.read => {
            // The loop the tail of this body re-enters when a chunked read
            // has more to collect.
            while (true) {
                const buffer = state.buf;
                var bytes_left = state.bytes_left;
                // `bytes_left` is a decremented remainder and the three reads
                // below already narrow it to a `usize`, so a negative one would
                // trap there whatever this clamp did; the conversion is here,
                // once, instead.
                const read_limit: usize = @intCast(if (state.is_chunk != 0)
                    (if (bytes_left > 4096) 4096 else bytes_left)
                else
                    bytes_left);
                try buffers.extra(buffer, read_limit);
                var nread: isize = undefined;
                var saddr: [256]u8 = undefined;
                var socklen: c_uint = @intCast(saddr.len);
                const dest = buffer.data.? + @as(usize, @intCast(buffer.count));
                if (has_net and state.mode == read_mode_recvfrom) {
                    nread = c.retryIntr(c.recvfrom, .{ s.handle, dest, @as(usize, @intCast(read_limit)), state.flags, &saddr, &socklen });
                } else if (has_net and state.mode == read_mode_recv) {
                    nread = c.retryIntr(c.recv, .{ s.handle, dest, @as(usize, @intCast(read_limit)), state.flags });
                } else {
                    nread = c.retryIntr(c.read, .{ s.handle, dest, @as(usize, @intCast(read_limit)) });
                }

                // Check for errors, special-casing the ones that can be fixed
                // by waiting.
                if (nread == -1) {
                    if (c.errno() == ev.EAGAIN or c.errno() == ev.EWOULDBLOCK) return;
                    // In stream protocols, a pipe error is end of stream.
                    if (c.errno() == ev.EPIPE and state.mode != read_mode_recvfrom) {
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

                buffer.count += @intCast(nread);
                bytes_left -= @intCast(nread);
                state.bytes_left = bytes_left;

                if (state.is_chunk == 0 or bytes_left == 0 or nread == 0) {
                    var resume_val: repr.Value = undefined;
                    if (has_net and state.mode == read_mode_recvfrom) {
                        const abst = abstracts.newBytes(&net.addressType, socklen);
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

/// The completion-port read, which copies through a fixed buffer.
fn readWindows(fiber: *fibers.Fiber, s: *Stream, state: *StateRead, event: ev.AsyncEvent) raise.Error!void {
    var start_transfer = false;
    switch (event) {
        constants.AsyncEvent.failed, constants.AsyncEvent.complete => {
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
                    const abst = abstracts.newBytes(&net.addressType, @intCast(state.fromlen));
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
        constants.AsyncEvent.init => start_transfer = true,
        else => {},
    }
    if (!start_transfer) return;

    const chunk = if (state.bytes_left > chunk_size_windows) chunk_size_windows else state.bytes_left;
    state.overlapped = std.mem.zeroes(Overlapped);
    if (has_net and state.mode == read_mode_recvfrom) {
        state.wbuf.len = @intCast(chunk);
        state.wbuf.buf = &state.chunk_buf;
        state.fromlen = @intCast(state.from.len);
        const status = c.WSARecvFrom(
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
        if (status != 0 and c.WSAGetLastError() != WSA_IO_PENDING) {
            try ev.cancel(fiber, evLasterr());
            ev.asyncEnd(fiber);
            return;
        }
    } else {
        // Some handles (not all) read from the offset in lpOverlapped; if it
        // is not set before calling ReadFile those streams always read from
        // offset 0.
        state.overlapped.as.Offset = @bitCast(state.bytes_read);
        const status = c.ReadFile(s.handle, &state.chunk_buf, @intCast(chunk), null, &state.overlapped.as);
        if (status == 0 and c.GetLastError() != ERROR_IO_PENDING) {
            if (c.GetLastError() == ERROR_BROKEN_PIPE) {
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

/// The collector finalising a stream: closes the handle and lets it go.
///
/// `closeImplHandle` raises when the backend refuses to unregister the
/// descriptor, a failed `epoll_ctl` or `kevent`. This is the one `gc` in the
/// tree that could, and it is discarded here rather than reported, because
/// there is nobody to report it to: the stream is already unreachable, the
/// handle is being closed either way, and no caller can retry a close. The
/// file comment on `abstract_type.AbstractType` has the contract.
fn streamGC(stream: *Stream, _: usize) void {
    closeImplHandle(stream) catch {};
}

/// The method lookup behind `(:read s ...)` and its siblings.
fn streamGetter(stream: *Stream, key: repr.Value) raise.Error!?repr.Value {
    return args_core.findMethod(key, @ptrCast(@alignCast(stream.methods)));
}

/// Traces the two waiting fibers.
fn streamMark(stream: *Stream, _: usize) void {
    if (stream.read_fiber) |rf| gc_mark.mark(wrap.fromFiber(rf));
    if (stream.write_fiber) |wf| gc_mark.mark(wrap.fromFiber(wf));
}

/// Writes the descriptor and the flags, which only an unsafe marshal may do.
fn streamMarshal(s: *Stream, m: *abi.Marshal) raise.Error!void {
    if (marsh.marshalFlags(m) & constants.marshal_unsafe == 0) {
        return raise.panic("can only marshal stream with unsafe flag");
    }
    // This stream might now be duplicated, which invalidates some EV
    // optimizations.
    s.flags &= ~stream_nodups;
    marsh.marshalAbstract(m, s);
    try marsh.marshalInt(m, @bitCast(s.flags));
    try marsh.marshalPtr(m, s.methods);
    if (windows) {
        // Unresolved: there is no reference counting to stop a handle being
        // closed or collected in transit, and `c.DuplicateHandle` does not
        // work for sockets.
        var duph: ?*anyopaque = invalidHandle();
        if (s.flags & stream_socket != 0) {
            duph = s.handle;
        } else {
            _ = c.DuplicateHandle(
                c.GetCurrentProcess(),
                s.handle,
                c.GetCurrentProcess(),
                &duph,
                0,
                0,
                DUPLICATE_SAME_ACCESS,
            );
        }
        try marsh.marshalInt64(m, @bitCast(@intFromPtr(duph)));
    } else {
        // Marshal after dup because it is easier than maintaining our own
        // reference counting.
        const duph = c.dup(s.handle);
        if (duph < 0) return pp_format.panicf("failed to duplicate stream handle: %V", .{evLasterr()});
        try marsh.marshalInt(m, duph);
    }
}

/// The iteration order behind `next` and `(keys s)`.
fn streamNext(stream: *Stream, key: repr.Value) raise.Error!repr.Value {
    return args_core.nextmethod(@ptrCast(@alignCast(stream.methods)), key);
}

/// `[fd=N]`, so that a program can print the descriptor when debugging.
///
/// A `host.Handle` is wider than the `%d` that renders it on Windows, so the
/// narrowing is written here rather than left to a conversion: away from
/// Windows the handle is already an `i32` and the truncation is exact.
fn streamToString(stream: *Stream, render: *abi.Render) raise.Error!void {
    const shown: i32 = if (windows) @truncate(@as(isize, @bitCast(@intFromPtr(stream.handle)))) else stream.handle;
    // The slot takes `abi.Render`, the capability a module author is offered in
    // place of the buffer's layout. This type is the runtime's own and never
    // crosses, so it recovers `buffers.Buffer` here and formats with an
    // ordinary Zig call. `abi.zig`'s header has the rule.
    _ = try pp_format.formatb(@ptrCast(@alignCast(render)), "[fd=%d]", .{shown});
}

/// Reattaches a descriptor read back out of a stream, and registers it.
fn streamUnmarshal(u: *abi.Unmarshal) raise.Error!*Stream {
    if (marsh.unmarshalFlags(u) & constants.marshal_unsafe == 0) {
        return raise.panic("can only unmarshal stream with unsafe flag");
    }
    const p: *Stream = @ptrCast(@alignCast(try marsh.unmarshalAbstract(u, @sizeOf(Stream))));
    // Listening state cannot be shared across threads.
    p.read_fiber = null;
    p.write_fiber = null;
    p.flags = @bitCast(try marsh.unmarshalInt(u));
    p.methods = try marsh.unmarshalPtr(u);
    if (windows) {
        p.handle = @ptrFromInt(@as(usize, @bitCast(try marsh.unmarshalInt64(u))));
    } else {
        p.handle = try marsh.unmarshalInt(u);
    }
    // The descriptor is this VM's own, from the `dup` the marshal made, so it
    // is registered here the way `makeStreamExt` registers a fresh one. Every
    // backend needs that: a kqueue filter, an `epoll_ctl` registration and a
    // completion port association are each keyed by descriptor, and `poll`
    // keeps a table of its own. Without it the speculative operation
    // `asyncStart` performs is the only one that can complete, and a read that
    // has to wait never wakes.
    try backend.registerStream(p);
    return p;
}

/// The POSIX write, straight from the caller's bytes.
fn writePosix(fiber: *fibers.Fiber, s: *Stream, state: *StateWrite, event: ev.AsyncEvent) raise.Error!void {
    switch (event) {
        constants.AsyncEvent.err => {
            try ev.cancel(fiber, value.fromBytes("stream err", .string));
            ev.asyncEnd(fiber);
        },
        constants.AsyncEvent.hup => {
            try ev.cancel(fiber, value.fromBytes("stream hup", .string));
            ev.asyncEnd(fiber);
        },
        constants.AsyncEvent.init, constants.AsyncEvent.write => {
            var len: i32 = undefined;
            var bytes: [*]const u8 = undefined;
            var start = state.start;
            if (state.is_buffer != 0) {
                const buffer = state.src.buf;
                bytes = buffer.data.?;
                len = @intCast(buffer.count);
            } else {
                bytes = state.src.str;
                len = @intCast(strings.head(bytes).length);
            }
            var nwrote: isize = 0;
            if (start < len) {
                const nbytes = len - start;
                const dest_abst = state.dest_abst;
                const from = bytes + @as(usize, @intCast(start));
                if (has_net and state.mode == write_mode_sendto) {
                    nwrote = c.retryIntr(c.sendto, .{ s.handle, from, @as(usize, @intCast(nbytes)), state.flags, dest_abst, @as(c_uint, @intCast(abi.abstractHead(dest_abst).size)) });
                } else if (has_net and state.mode == write_mode_send) {
                    nwrote = c.retryIntr(c.send, .{ s.handle, from, @as(usize, @intCast(nbytes)), state.flags });
                } else {
                    nwrote = c.retryIntr(c.write, .{ s.handle, from, @as(usize, @intCast(nbytes)) });
                }

                if (nwrote == -1) {
                    if (c.errno() == ev.EAGAIN or c.errno() == ev.EWOULDBLOCK) return;
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

/// The completion-port write, which copies through a fixed buffer.
fn writeWindows(fiber: *fibers.Fiber, s: *Stream, state: *StateWrite, event: ev.AsyncEvent) raise.Error!void {
    switch (event) {
        constants.AsyncEvent.failed, constants.AsyncEvent.complete => {
            const ev_bytes: u32 = @truncate(state.overlapped.bytes_transfered);
            if (ev_bytes == 0 and state.mode != write_mode_sendto) {
                try ev.cancel(fiber, value.fromBytes("disconnect", .string));
                ev.asyncEnd(fiber);
                return;
            }
            ev.schedule(fiber, wrap.fromNil());
            ev.asyncEnd(fiber);
        },
        constants.AsyncEvent.init => {
            var len: i32 = undefined;
            var bytes: [*]const u8 = undefined;
            if (state.is_buffer != 0) {
                // If a buffer, convert to a string. Unresolved: this copies
                // where it could send from the buffer.
                const buffer = state.src.buf;
                const str = strings.new(buffer.slice());
                bytes = str;
                len = @intCast(buffer.count);
                state.is_buffer = 0;
                state.src.str = str;
            } else {
                bytes = state.src.str;
                len = @intCast(strings.head(bytes).length);
            }
            state.overlapped = std.mem.zeroes(Overlapped);

            if (has_net and state.mode == write_mode_sendto) {
                state.wbuf.buf = @constCast(bytes);
                state.wbuf.len = @intCast(len);
                const to = state.dest_abst;
                const tolen: c_int = @intCast(abi.abstractHead(to).size);
                const status = c.WSASendTo(
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
                    if (c.WSAGetLastError() == WSA_IO_PENDING) {
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
                const status = c.WriteFile(s.handle, bytes, @intCast(len), null, &state.overlapped.as);
                if (status == 0) {
                    if (c.GetLastError() == ERROR_IO_PENDING) {
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
