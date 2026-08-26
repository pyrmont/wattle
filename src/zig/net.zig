//! The `net/` module: sockets, and the addresses they bind and connect to.
//!
//! `net_sockets.zig` and `net_addr.zig` until Phase 12 increment 6f. The split
//! was between the cfunctions and the address vocabulary they hand around, and
//! `net_sockets.zig` already bound the other half at every use -- nineteen
//! names, most of them aliases to it rather than declarations of its own.
//! `port/TREE.md` gives them one name because Janet publishes one module, with
//! `net/abi.zig` beside it for the host translation.
const std = @import("std");
const builtin = @import("builtin");
const corefn = @import("corefn");
const net_abi = @import("net/abi.zig");
const raise = @import("raise");
const pp_format = @import("pp/format.zig");
const types = @import("types");
const constants = @import("constants");
const c = @import("cabi");
const ev_loop = @import("ev.zig");
const ev_stream = @import("ev/stream.zig");
const vm_lifecycle = @import("vm/lifecycle.zig");
const abstract_type = @import("abstract_type.zig");
const method_type = @import("method_type.zig");
const utils = @import("utils.zig");
const gc_mark = @import("gc/mark.zig");
const kind = @import("value/helpers/kind.zig");
const wrap = @import("value/helpers/wrap.zig");
const args_core = @import("args.zig");
const fibers = @import("value/fibers.zig");
const stdio = @import("stdio.zig");
const arrays = @import("value/arrays.zig");
const tuples = @import("value/tuples.zig");
const value = @import("value.zig");
const abstracts = @import("value/abstracts.zig");
const pp_describe = @import("pp.zig");

// -------------------------------------------------------------------------
// The cfunctions -- what `net_sockets.zig` was.
// -------------------------------------------------------------------------

const h = net_abi.h;
const windows = net_abi.windows;
const JSock = net_abi.JSock;

const stream_readable: u32 = @intCast(constants.JANET_STREAM_READABLE);
const stream_writable: u32 = @intCast(constants.JANET_STREAM_WRITABLE);
const stream_acceptable: u32 = @intCast(constants.JANET_STREAM_ACCEPTABLE);
const stream_udpserver: u32 = @intCast(constants.JANET_STREAM_UDPSERVER);
const stream_socket: u32 = @intCast(constants.JANET_STREAM_SOCKET);
const stream_nodups: u32 = @intCast(constants.JANET_STREAM_NODUPS);
const stream_closed: u32 = @intCast(constants.JANET_STREAM_CLOSED);
const stream_toclose: u32 = @intCast(constants.JANET_STREAM_TOCLOSE);

inline fn vm() *types.JanetVM {
    return c.vm();
}

inline fn errno() c_int {
    return std.c._errno().*;
}

// ==========================================================================
// The event loop's C ABI
// ==========================================================================

/// `src/core/util.h`, declared here rather than in `cabi.zig`.
extern fn janet_strerror(e: c_int) callconv(.c) [*:0]const u8;

/// The four stream methods `net_stream_methods` shares with `ev/`. They are
/// `-Dev-loop`'s, under both of its arms.

// ==========================================================================
// Sockets
// ==========================================================================

/// `make_stream`. Every socket this file produces is `NODUPS`, which is what
/// lets `janet_stream_close` skip the unregister: nothing has duplicated the
/// descriptor, so closing it removes it from the poll set for free.
///
/// Raising, since Phase 11 Part 15: `registerStream` refuses a descriptor the
/// backend will not take, and every caller below is inside a `raise.Raising`
/// function — the four cfunctions, and both halves of the accept callback,
/// because `ev_callback.EVCallback` is `raise.Error!void` too. They reached
/// the abi until that part, so the refusal became a report nobody consumed
/// and `raise.reported`'s `blank(*JanetStream)` — a null pointer — was
/// dereferenced on top of it.
fn makeStream(handle: JSock, flags: u32) raise.Raising(*types.JanetStream) {
    const jh: types.JanetHandle = if (windows) @ptrFromInt(handle) else handle;
    return ev_loop.makeStream(jh, flags | stream_socket | stream_nodups, @ptrCast(&net_stream_methods));
}

/// `janet_net_socknoblock`: make sure a socket does not block, and on the
/// platforms that have it ask for `SO_NOSIGPIPE` so that a write to a closed
/// peer is an `EPIPE` rather than a signal.
///
/// Every result is discarded, as in the C original. A socket that refuses to
/// go non-blocking is not reported here and shows up later as a would-block
/// that never arrives.
fn sockNoBlock(s: JSock) void {
    if (windows) {
        var arg: h.u_long = 1;
        _ = h.ioctlsocket(s, net_abi.fionbio, &arg);
    } else {
        // `SOCK_CLOEXEC` is asked for at `socket(2)` where the platform has
        // it; where it does not, `O_CLOEXEC` is set here instead.
        const extra: c_int = if (@hasDecl(h, "SOCK_CLOEXEC")) 0 else h.O_CLOEXEC;
        _ = h.fcntl(s, h.F_SETFL, h.fcntl(s, h.F_GETFL, @as(c_int, 0)) | h.O_NONBLOCK | extra);
        if (@hasDecl(h, "SO_NOSIGPIPE")) {
            const enable: c_int = 1;
            _ = net_abi.setSockOpt(s, h.SOL_SOCKET, h.SO_NOSIGPIPE, &enable, @sizeOf(c_int));
        }
    }
}

/// `serverify_socket`: the options a listening socket wants, and null unless
/// one of them failed.
fn serverifySocket(sfd: JSock, reuse_addr: bool, reuse_port: bool) ?[*:0]const u8 {
    const enable: c_int = 1;
    if (reuse_addr) {
        if (net_abi.setSockOpt(sfd, h.SOL_SOCKET, h.SO_REUSEADDR, &enable, @sizeOf(c_int)) < 0) {
            return "setsockopt(SO_REUSEADDR) failed";
        }
    }
    if (reuse_port) {
        if (net_abi.has_reuseport) {
            if (net_abi.setSockOpt(sfd, h.SOL_SOCKET, h.SO_REUSEPORT, &enable, @sizeOf(c_int)) < 0) {
                return "setsockopt(SO_REUSEPORT) failed";
            }
        }
    }
    sockNoBlock(sfd);
    return null;
}

/// `socket(2)`, spelled as each platform's socket layer wants it. Windows
/// needs `WSASocketW` with `WSA_FLAG_OVERLAPPED` because every transfer on it
/// goes through the completion port.
fn openSocket(family: c_int, socktype: c_int, protocol: c_int) JSock {
    if (windows) {
        return h.WSASocketW(family, socktype, protocol, null, 0, h.WSA_FLAG_OVERLAPPED);
    }
    return h.socket(family, socktype | net_abi.sock_flags, protocol);
}

// ==========================================================================
// The connect state machine
// ==========================================================================

/// `JanetOverlapped` from `src/core/util.h`, restated for the same reason
/// `ev_stream.zig` restates it: nothing translates that header, and
/// Zig 0.16's `std.os.windows` no longer declares `OVERLAPPED` at all. The C
/// original spells the first member as a union of `OVERLAPPED` and
/// `WSAOVERLAPPED`, which have the same layout, so one arm is enough.
const OVERLAPPED = extern struct {
    Internal: usize,
    InternalHigh: usize,
    Offset: u32,
    OffsetHigh: u32,
    hEvent: ?*anyopaque,
};

const Overlapped = extern struct {
    as: OVERLAPPED,
    bytes_transfered: u32,
};

/// `NetStateConnect`. Only the `ConnectEx` path uses it; the POSIX path passes
/// a null state and reads everything it needs off the stream.
const NetStateConnect = extern struct {
    overlapped: Overlapped,
};

/// `lazy_get_connectex`. `ConnectEx` is not exported by any import library and
/// has to be asked for by GUID, once per VM.
fn lazyGetConnectEx(sock: JSock) h.LPFN_CONNECTEX {
    if (vm().connect_ex_loaded != 0) return @ptrCast(vm().connect_ex);
    var guid = net_abi.wsaid_connectex;
    var connect_ex_ptr: h.LPFN_CONNECTEX = null;
    var byte_len: h.DWORD = 0;
    const success = h.WSAIoctl(
        sock,
        h.SIO_GET_EXTENSION_FUNCTION_POINTER,
        @ptrCast(&guid),
        @sizeOf(h.GUID),
        @ptrCast(&connect_ex_ptr),
        @sizeOf(h.LPFN_CONNECTEX),
        &byte_len,
        null,
        null,
    );
    vm().connect_ex = if (success != 0) null else @ptrCast(@constCast(connect_ex_ptr));
    vm().connect_ex_loaded = 1;
    return @ptrCast(vm().connect_ex);
}

fn net_callback_connect(fiber: *types.JanetFiber, event: types.JanetAsyncEvent) raise.Raising(void) {
    const stream: *types.JanetStream = fiber.*.ev_stream.?;
    switch (event) {
        // Windows does not support an async connect through this path and
        // just tries immediately; everywhere else, wait for a real event
        // before looking at the result.
        constants.JANET_ASYNC_EVENT_INIT => if (!windows) return,
        constants.JANET_ASYNC_EVENT_DEINIT => return,
        constants.JANET_ASYNC_EVENT_CLOSE => {
            try ev_loop.cancel(fiber, value.fromBytes("stream closed", .string));
            ev_loop.asyncEnd(fiber);
            return;
        },
        else => {},
    }

    var res: c_int = 0;
    var size: SockLen = @sizeOf(c_int);
    var r: c_int = undefined;
    var no_error: c_int = undefined;
    if (windows) {
        // We should be using ConnectEx here.
        r = net_abi.getSockOpt(sockOf(stream), h.SOL_SOCKET, h.SO_CONNECT_TIME, &res, &size);
        // This apparently indicates we haven't yet gotten a connection.
        if (r == h.NO_ERROR and res == -1) return;
        no_error = h.NO_ERROR;
    } else {
        r = net_abi.getSockOpt(sockOf(stream), h.SOL_SOCKET, h.SO_ERROR, &res, &size);
        no_error = 0;
    }

    if (r == no_error) {
        if (res == 0) {
            ev_loop.schedule(fiber, wrap.fromAbstract(stream));
        } else {
            try ev_loop.cancel(fiber, value.fromBytes(std.mem.span(janet_strerror(res)), .string));
            stream.flags |= stream_toclose;
        }
    } else {
        try ev_loop.cancel(fiber, ev_stream.evLasterr());
        stream.flags |= stream_toclose;
    }
    ev_loop.asyncEnd(fiber);
}

/// `net_sched_connect`.
fn schedConnect(stream: *types.JanetStream, state: ?*anyopaque) raise.Error {
    return ev_loop.asyncStart(stream, constants.JANET_ASYNC_LISTEN_WRITE, net_callback_connect, state);
}

// ==========================================================================
// The accept state machine
// ==========================================================================

/// `NetStateAccept`. The two platforms share a name and nothing else: the
/// completion port has to have an accepting socket and a buffer ready
/// *before* a connection arrives, so the Windows state carries both, while
/// the POSIX one carries only the handler function and calls `accept(2)` when
/// the descriptor says there is something to take.
const NetStateAccept = if (windows) extern struct {
    overlapped: Overlapped,
    function: ?*types.JanetFunction,
    lstream: ?*types.JanetStream,
    astream: ?*types.JanetStream,
    buf: [1024]u8,
} else extern struct {
    function: ?*types.JanetFunction,
};

fn net_callback_accept(fiber: *types.JanetFiber, event: types.JanetAsyncEvent) raise.Raising(void) {
    const state: *NetStateAccept = @ptrCast(@alignCast(fiber.*.ev_state));
    switch (event) {
        constants.JANET_ASYNC_EVENT_MARK => {
            if (windows) {
                if (state.lstream) |s| gc_mark.mark(wrap.fromAbstract(s));
                if (state.astream) |s| gc_mark.mark(wrap.fromAbstract(s));
            }
            if (state.function) |f| gc_mark.mark(wrap.fromFunction(f));
        },
        constants.JANET_ASYNC_EVENT_CLOSE => {
            ev_loop.schedule(fiber, wrap.fromNil());
            ev_loop.asyncEnd(fiber);
        },
        else => {
            if (windows) {
                try acceptWindows(fiber, state, event);
            } else {
                try acceptPosix(fiber, state, event);
            }
        },
    }
}

fn acceptWindows(fiber: *types.JanetFiber, state: *NetStateAccept, event: types.JanetAsyncEvent) raise.Raising(void) {
    if (event != constants.JANET_ASYNC_EVENT_COMPLETE) return;
    const astream = state.astream.?;
    if (astream.flags & stream_closed != 0) {
        try ev_loop.cancel(fiber, value.fromBytes("failed to accept connection", .string));
        ev_loop.asyncEnd(fiber);
        return;
    }
    const lsock = sockOf(state.lstream.?);
    if (net_abi.setSockOpt(
        sockOf(astream),
        h.SOL_SOCKET,
        h.SO_UPDATE_ACCEPT_CONTEXT,
        &lsock,
        @sizeOf(JSock),
    ) != h.NO_ERROR) {
        try ev_loop.cancel(fiber, value.fromBytes("failed to accept connection", .string));
        ev_loop.asyncEnd(fiber);
        return;
    }

    const streamv = wrap.fromAbstract(astream);
    if (state.function) |f| {
        // Schedule the worker, then listen again for the next connection.
        // `.?` for the reason the POSIX arm above gives: the C original
        // dereferences whatever `janet_fiber` answered, and it answers null
        // when the handler's arity rejects one argument. `port/FOUND.md`.
        const sub_fiber = fibers.new(f, 64, 1, @ptrCast(&streamv)).?;
        sub_fiber.*.supervisor_channel = fiber.*.supervisor_channel;
        ev_loop.schedule(sub_fiber, wrap.fromNil());
        var err: types.Janet = undefined;
        if (try schedAcceptImpl(state, fiber, &err)) {
            try ev_loop.cancel(fiber, err);
            ev_loop.asyncEnd(fiber);
        }
    } else {
        ev_loop.schedule(fiber, streamv);
        ev_loop.asyncEnd(fiber);
    }
}

/// Raising, as `acceptWindows` beside it already was. A callback in this fork
/// is `raise.Error!void`, so an accept whose stream the backend refuses
/// reports the way that function's `failed to accept connection` does rather
/// than carrying on with a null stream.
fn acceptPosix(fiber: *types.JanetFiber, state: *NetStateAccept, event: types.JanetAsyncEvent) raise.Raising(void) {
    if (event != constants.JANET_ASYNC_EVENT_INIT and event != constants.JANET_ASYNC_EVENT_READ) return;
    const stream: *types.JanetStream = fiber.*.ev_stream.?;
    const connfd: JSock = if (builtin.os.tag == .linux)
        net_abi.accept4(sockOf(stream), null, null, h.SOCK_CLOEXEC)
    else
        // On BSDs, CLOEXEC should be inherited from server socket.
        net_abi.accept(sockOf(stream), null, null);
    if (!net_abi.sockValid(connfd)) return;

    sockNoBlock(connfd);
    const astream = try makeStream(connfd, stream_readable | stream_writable);
    const streamv = wrap.fromAbstract(astream);
    if (state.function) |f| {
        // `.?` rather than a check, because the C original has none: it
        // dereferences whatever `janet_fiber` answered. It answers null when
        // the handler's arity rejects one argument, so a `net/server` given a
        // handler of the wrong arity segfaults upstream. The unwrap makes that
        // a named panic instead of a null store, and only on the path C leaves
        // undefined; `port/FOUND.md` records the C side. Batch 3 surfaced it
        // by giving `janet_fiber` a Zig return type -- `[*c]JanetFiber` from
        // the header let the deref through without a word.
        const sub_fiber = fibers.new(f, 64, 1, @ptrCast(&streamv)).?;
        sub_fiber.*.supervisor_channel = fiber.*.supervisor_channel;
        ev_loop.schedule(sub_fiber, wrap.fromNil());
    } else {
        ev_loop.schedule(fiber, streamv);
        ev_loop.asyncEnd(fiber);
    }
}

/// `net_sched_accept_impl`, the Windows half: put an accepting socket and a
/// buffer in flight. True on failure, with `*err` set.
fn schedAcceptImpl(state: *NetStateAccept, fiber: *types.JanetFiber, err: *types.Janet) raise.Raising(bool) {
    const lsock = sockOf(state.lstream.?);
    const asock = h.WSASocketW(h.AF_INET, h.SOCK_STREAM, h.IPPROTO_TCP, null, 0, h.WSA_FLAG_OVERLAPPED);
    if (asock == h.INVALID_SOCKET) {
        err.* = ev_stream.evLasterr();
        return true;
    }
    // `try` rather than this function's `err`/`true` protocol: that protocol
    // is for a failure `janet_ev_lasterr` describes, and a refused
    // registration already carries its own message.
    state.astream = try makeStream(asock, stream_readable | stream_writable);
    const socksize: h.DWORD = @sizeOf(h.SOCKADDR_STORAGE) + 16;
    if (h.AcceptEx(lsock, asock, &state.buf, 0, socksize, socksize, null, @ptrCast(&state.overlapped.as)) == 0) {
        if (h.WSAGetLastError() == h.WSA_IO_PENDING) {
            // Indicates io is happening async.
            ev_loop.asyncInFlight(fiber);
            return false;
        }
        err.* = ev_stream.evLasterr();
        return true;
    }
    return false;
}

/// `janet_sched_accept`.
fn schedAccept(stream: *types.JanetStream, fun: ?*types.JanetFunction) raise.Error {
    const state: *NetStateAccept = @ptrCast(@alignCast(
        utils.malloc(@sizeOf(NetStateAccept)) orelse outOfMemory(@src()),
    ));
    state.* = std.mem.zeroes(NetStateAccept);
    state.function = fun;
    if (windows) {
        state.lstream = stream;
        var err: types.Janet = undefined;
        if (try schedAcceptImpl(state, fibers.root().?, &err)) {
            utils.free(state);
            return raise.panicv(err);
        }
    } else {
        // A handler runs on its own fiber and the listener goes straight back
        // to waiting, so the readiness has to persist rather than be consumed
        // by the edge that reported it.
        if (fun != null) try ev_loop.levelTriggeredStream(stream);
    }
    return ev_loop.asyncStart(stream, constants.JANET_ASYNC_LISTEN_READ, net_callback_accept, state);
}

// ==========================================================================
// The cfunctions
// ==========================================================================

fn getStream(argv: []const types.Janet, n: i32) raise.Raising(*types.JanetStream) {
    return @ptrCast(@alignCast(try args_core.getAbstract(argv, n, abstract_type.stored(&ev_stream.streamType))));
}

// The stream type is reached through the `ev_stream` import at the head of
// this file. It was an `extern const janet_stream_type` here until Phase 11
// Part 22 -- declared beside an import of the very file that defines it, which
// is the same thing `ev_loop.zig` was doing.

/// `cfun_net_connect`, registered as `net/connect`.
fn connectImpl(argv: []types.Janet) raise.Raising(types.Janet) {
    try vm_lifecycle.sandboxAssert(constants.JANET_SANDBOX_NET_CONNECT);
    try args_core.arity(argv, 2, 5);

    // Check arguments.
    const socktype = try socketType(argv, 2);
    const bindhost = try args_core.optCString(argv, 3, null);
    const bindport = if (@as(i32, @intCast(argv.len)) >= 5 and args_core.checkint(argv[4]) != 0)
        pp_describe.toString(argv[4])
    else
        try args_core.optCString(argv, 4, null);

    // Where we're connecting to.
    var info = try getAddrInfo(argv, 0, socktype, false);
    var addrlen: SockLen = info.size;

    // Check if we're binding address.
    var binding: ?*h.struct_addrinfo = null;
    if (bindhost != null) {
        if (info.isUnix()) {
            // `net.c` releases this one with `freeaddrinfo`, which did not
            // allocate it. That is undefined rather than merely wrong, so the
            // port releases it correctly; `FOUND.md` has the entry.
            info.free();
            return raise.panic("bindhost not supported for unix domain sockets");
        }
        var hints = std.mem.zeroes(h.struct_addrinfo);
        hints.ai_family = h.AF_UNSPEC;
        hints.ai_socktype = socktype;
        hints.ai_flags = 0;
        const status = h.getaddrinfo(bindhost, bindport, &hints, &binding);
        if (status != 0) {
            info.free();
            return pp_format.panicf(
                "could not get address info for bindhost: %s",
                .{net_abi.gaiStrerror(status)},
            );
        }
    }

    // Create socket.
    var sock: JSock = net_abi.sock_default;
    var sa: ?*const h.struct_sockaddr = null;
    var is_unix_socket = false;
    if (!windows) {
        if (info.un) |un| {
            is_unix_socket = true;
            sock = h.socket(h.AF_UNIX, socktype | net_abi.sock_flags, 0);
            if (!net_abi.sockValid(sock)) {
                const v = ev_stream.evLasterr();
                info.free();
                return pp_format.panicf("could not create socket: %V", .{v});
            }
            sa = @ptrCast(@alignCast(un));
        }
    }
    if (!is_unix_socket) {
        var rp = info.ai;
        while (rp != null) : (rp = rp.?.ai_next) {
            sock = openSocket(rp.?.ai_family, rp.?.ai_socktype, rp.?.ai_protocol);
            if (net_abi.sockValid(sock)) {
                sa = rp.?.ai_addr;
                addrlen = @intCast(rp.?.ai_addrlen);
                break;
            }
        }
        if (sa == null) {
            const v = ev_stream.evLasterr();
            if (binding != null) h.freeaddrinfo(binding);
            info.free();
            return pp_format.panicf("could not create socket: %V", .{v});
        }
    }

    // Bind to bindhost and bindport if given.
    if (binding != null) {
        var did_bind = false;
        var rp = binding;
        while (rp != null) : (rp = rp.?.ai_next) {
            if (net_abi.bind(sock, rp.?.ai_addr, @intCast(rp.?.ai_addrlen)) == 0) {
                did_bind = true;
                break;
            }
        }
        if (!did_bind) {
            const v = ev_stream.evLasterr();
            h.freeaddrinfo(binding);
            info.free();
            net_abi.sockClose(sock);
            return pp_format.panicf("could not bind outgoing address: %V", .{v});
        }
        h.freeaddrinfo(binding);
    }

    // Wrap socket in abstract type JanetStream.
    const udp_flag: u32 = if (socktype == h.SOCK_DGRAM) stream_udpserver else 0;
    const stream = try makeStream(sock, stream_readable | stream_writable | udp_flag);

    // Connect to socket.
    var status: c_int = undefined;
    var err: c_int = 0;
    if (windows) {
        if (socktype == h.SOCK_STREAM) {
            if (lazyGetConnectEx(sock)) |connect_ex| {
                // Prefer ConnectEx as it works well with overlapped IO.
                sockNoBlock(sock);
                const state: *NetStateConnect = @ptrCast(@alignCast(
                    utils.malloc(@sizeOf(NetStateConnect)) orelse outOfMemory(@src()),
                ));
                state.* = std.mem.zeroes(NetStateConnect);
                const success = connect_ex(sock, sa, @intCast(addrlen), null, 0, null, @ptrCast(&state.overlapped.as));
                info.free();
                if (success == 0 and h.WSAGetLastError() != h.ERROR_IO_PENDING) {
                    utils.free(state);
                    const lasterr = ev_stream.evLasterr();
                    return pp_format.panicf("could not connect socket (ConnectEx): %V", .{lasterr});
                }
                return schedConnect(stream, state);
            }
        }
        // Default to blocking connect if ConnectEx not available.
        status = h.WSAConnect(sock, sa, @intCast(addrlen), null, null, null, null);
        err = h.WSAGetLastError();
        info.free();
        // Set up the socket for non-blocking IO after connecting on windows.
        sockNoBlock(sock);
    } else {
        // Set up the socket for non-blocking IO before connecting.
        sockNoBlock(sock);
        while (true) {
            status = net_abi.connect(sock, sa, addrlen);
            if (!(status == -1 and errno() == h.EINTR)) break;
        }
        err = errno();
        info.free();
    }

    if (status == 0) {
        // Connect completed synchronously (common for unix domain sockets).
        // Return the stream directly without scheduling an async wait, as
        // edge-triggered kqueue may not signal EVFILT_WRITE if the socket is
        // already connected when registered.
        return wrap.fromAbstract(stream);
    }

    const failed = if (windows) status == h.SOCKET_ERROR else status == -1;
    const would_block = if (windows) h.WSAEWOULDBLOCK else h.EINPROGRESS;
    if (failed and err != would_block) {
        // The stream above already owns this handle, and its finalizer will
        // close it again -- by which point the number may belong to something
        // else. `FOUND.md` has the entry and a reproducer that loses a
        // `file/open`'s writes. Closing a valid descriptor is defined, so the
        // port reproduces the sequence rather than repairing it.
        net_abi.sockClose(sock);
        const lasterr = ev_stream.evLasterr();
        return pp_format.panicf("could not connect socket: %V", .{lasterr});
    }

    return schedConnect(stream, null);
}

/// `cfun_net_socket`, registered as `net/socket`.
fn socketImpl(argv: []types.Janet) raise.Raising(types.Janet) {
    try args_core.arity(argv, 0, 2);

    const socktype = try socketType(argv, 0);

    // Create socket.
    var sfd: JSock = net_abi.sock_default;
    var ai: ?*h.struct_addrinfo = null;
    var hints = std.mem.zeroes(h.struct_addrinfo);
    hints.ai_family = h.AF_UNSPEC;
    hints.ai_socktype = socktype;
    // Explicitly prevent name resolution where the platform can say so.
    hints.ai_flags = if (@hasDecl(h, "AI_NUMERICSERV")) h.AI_NUMERICSERV else 0;
    if (@as(i32, @intCast(argv.len)) >= 2) hints.ai_family = addressFamily(argv[1]);
    const status = h.getaddrinfo(null, "0", &hints, &ai);
    if (status != 0) {
        return pp_format.panicf("could not get address info: %s", .{net_abi.gaiStrerror(status)});
    }

    var rp = ai;
    while (rp != null) : (rp = rp.?.ai_next) {
        sfd = openSocket(rp.?.ai_family, rp.?.ai_socktype, rp.?.ai_protocol);
        if (net_abi.sockValid(sfd)) break;
    }
    h.freeaddrinfo(ai);

    if (!net_abi.sockValid(sfd)) {
        const v = ev_stream.evLasterr();
        return pp_format.panicf("could not create socket: %V", .{v});
    }

    // Wrap socket in abstract type JanetStream.
    const udp_flag: u32 = if (socktype == h.SOCK_DGRAM) stream_udpserver else 0;
    const stream = try makeStream(sfd, stream_readable | stream_writable | udp_flag);

    // Set up the socket for non-blocking IO.
    sockNoBlock(sfd);

    return wrap.fromAbstract(stream);
}

const shutdown_rw: c_int = if (windows) h.SD_BOTH else h.SHUT_RDWR;
const shutdown_r: c_int = if (windows) h.SD_RECEIVE else h.SHUT_RD;
const shutdown_w: c_int = if (windows) h.SD_SEND else h.SHUT_WR;

/// `cfun_net_shutdown`, registered as `net/shutdown`.
fn shutdownImpl(argv: []types.Janet) raise.Raising(types.Janet) {
    try args_core.arity(argv, 1, 2);
    const stream = try getStream(argv, 0);
    try ev_loop.streamFlags(stream, stream_socket);
    var shutdown_type = shutdown_rw;
    if (@as(i32, @intCast(argv.len)) == 2) {
        const kw = try args_core.getKeyword(argv, 1);
        if (utils.cstrcmp(kw, "rw") == 0) {
            shutdown_type = shutdown_rw;
        } else if (utils.cstrcmp(kw, "r") == 0) {
            shutdown_type = shutdown_r;
        } else if (utils.cstrcmp(kw, "w") == 0) {
            shutdown_type = shutdown_w;
        } else {
            return pp_format.panicf("unexpected keyword %v", .{argv[1]});
        }
    }
    var status: c_int = undefined;
    if (windows) {
        status = h.shutdown(sockOf(stream), shutdown_type);
    } else {
        while (true) {
            status = h.shutdown(sockOf(stream), shutdown_type);
            if (!(status == -1 and errno() == h.EINTR)) break;
        }
    }
    if (status != 0) {
        return pp_format.panicf("could not shutdown socket: %V", .{ev_stream.evLasterr()});
    }
    return argv[0];
}

/// `cfun_net_listen`, registered as `net/listen`.
fn listenImpl(argv: []types.Janet) raise.Raising(types.Janet) {
    try vm_lifecycle.sandboxAssert(constants.JANET_SANDBOX_NET_LISTEN);
    try args_core.arity(argv, 2, 4);

    // Get host, port, and handler.
    const socktype = try socketType(argv, 2);
    const info = try getAddrInfo(argv, 0, socktype, true);
    const reuse = !(@as(i32, @intCast(argv.len)) >= 4 and kind.truthy(argv[3]) != 0);

    var sfd: JSock = net_abi.sock_default;
    var bound = false;
    if (!windows) {
        if (info.un) |un| {
            bound = true;
            sfd = h.socket(h.AF_UNIX, socktype | net_abi.sock_flags, 0);
            if (!net_abi.sockValid(sfd)) {
                info.free();
                return pp_format.panicf("could not create socket: %V", .{ev_stream.evLasterr()});
            }
            const serr = serverifySocket(sfd, reuse, false);
            if (serr != null or net_abi.bind(sfd, @ptrCast(un), info.size) != 0) {
                net_abi.sockClose(sfd);
                info.free();
                if (serr) |message| return raise.panic(message);
                return pp_format.panicf("could not bind socket: %V", .{ev_stream.evLasterr()});
            }
            info.free();
        }
    }
    if (!bound) {
        // Check all addrinfos in a loop for the first that we can bind to.
        var rp = info.ai;
        while (rp != null) : (rp = rp.?.ai_next) {
            sfd = openSocket(rp.?.ai_family, rp.?.ai_socktype, rp.?.ai_protocol);
            if (!net_abi.sockValid(sfd)) continue;
            if (serverifySocket(sfd, reuse, reuse) != null) {
                net_abi.sockClose(sfd);
                continue;
            }
            if (net_abi.bind(sfd, rp.?.ai_addr, @intCast(rp.?.ai_addrlen)) == 0) break;
            net_abi.sockClose(sfd);
        }
        const found = rp != null;
        info.free();
        if (!found) return raise.panic("could not bind to any sockets");
    }

    if (socktype == h.SOCK_DGRAM) {
        // Datagram server (UDP).
        return wrap.fromAbstract(try makeStream(sfd, stream_udpserver | stream_readable));
    }

    // Stream server (TCP).
    if (h.listen(sfd, 1024) != 0) {
        net_abi.sockClose(sfd);
        return pp_format.panicf("could not listen on file descriptor: %V", .{ev_stream.evLasterr()});
    }
    // Put sfd on our loop.
    return wrap.fromAbstract(try makeStream(sfd, stream_acceptable));
}

/// `cfun_stream_accept_loop`, registered as `net/accept-loop`.
fn acceptLoopImpl(argv: []types.Janet) raise.Raising(types.Janet) {
    try args_core.fixarity(argv, 2);
    const stream = try getStream(argv, 0);
    try ev_loop.streamFlags(stream, stream_acceptable | stream_socket);
    const fun = try args_core.getFunction(argv, 1);
    if (fun.*.def.?.min_arity < 1) return raise.panic("handler function must take at least 1 argument");
    return schedAccept(stream, fun);
}

/// `cfun_stream_accept`, registered as `net/accept`.
fn acceptImpl(argv: []types.Janet) raise.Raising(types.Janet) {
    try args_core.arity(argv, 1, 2);
    const stream = try getStream(argv, 0);
    try ev_loop.streamFlags(stream, stream_acceptable | stream_socket);
    const to = try args_core.optNumber(argv, 1, std.math.inf(f64));
    if (to != std.math.inf(f64)) ev_loop.addtimeout(to);
    return schedAccept(stream, null);
}

/// `cfun_stream_read`, registered as `net/read`.
fn readImpl(argv: []types.Janet) raise.Raising(types.Janet) {
    try args_core.arity(argv, 2, 4);
    const stream = try getStream(argv, 0);
    try ev_loop.streamFlags(stream, stream_readable | stream_socket);
    const buffer = try args_core.optBuffer(argv, 2, 10);
    const to = try args_core.optNumber(argv, 3, std.math.inf(f64));
    if (args_core.keyeq(argv[1], "all") != 0) {
        if (to != std.math.inf(f64)) ev_loop.addtimeout(to);
        return ev_stream.readGeneric(stream, buffer, std.math.maxInt(i32), true, ev_stream.read_mode_recv, net_abi.msg_nosignal);
    } else {
        const n = try args_core.getNat(argv, 1);
        if (to != std.math.inf(f64)) ev_loop.addtimeout(to);
        return ev_stream.readGeneric(stream, buffer, n, false, ev_stream.read_mode_recv, net_abi.msg_nosignal);
    }
}

/// `cfun_stream_chunk`, registered as `net/chunk`.
fn chunkImpl(argv: []types.Janet) raise.Raising(types.Janet) {
    try args_core.arity(argv, 2, 4);
    const stream = try getStream(argv, 0);
    try ev_loop.streamFlags(stream, stream_readable | stream_socket);
    const n = try args_core.getNat(argv, 1);
    const buffer = try args_core.optBuffer(argv, 2, 10);
    const to = try args_core.optNumber(argv, 3, std.math.inf(f64));
    if (to != std.math.inf(f64)) ev_loop.addtimeout(to);
    return ev_stream.readGeneric(stream, buffer, n, true, ev_stream.read_mode_recv, net_abi.msg_nosignal);
}

/// `cfun_stream_recv_from`, registered as `net/recv-from`.
fn recvFromImpl(argv: []types.Janet) raise.Raising(types.Janet) {
    try args_core.arity(argv, 3, 4);
    const stream = try getStream(argv, 0);
    try ev_loop.streamFlags(stream, stream_udpserver | stream_socket);
    const n = try args_core.getNat(argv, 1);
    const buffer = try args_core.getBuffer(argv, 2);
    const to = try args_core.optNumber(argv, 3, std.math.inf(f64));
    if (to != std.math.inf(f64)) ev_loop.addtimeout(to);
    return ev_stream.readGeneric(stream, buffer, n, false, ev_stream.read_mode_recvfrom, net_abi.msg_nosignal);
}

/// `cfun_stream_write`, registered as `net/write`.
fn writeImpl(argv: []types.Janet) raise.Raising(types.Janet) {
    try args_core.arity(argv, 2, 3);
    const stream = try getStream(argv, 0);
    try ev_loop.streamFlags(stream, stream_writable | stream_socket);
    const to = try args_core.optNumber(argv, 2, std.math.inf(f64));
    if (kind.checkType(argv[1], constants.JANET_BUFFER) != 0) {
        if (to != std.math.inf(f64)) ev_loop.addtimeout(to);
        return ev_stream.writeGeneric(stream, try args_core.getBuffer(argv, 1), null, ev_stream.write_mode_send, true, net_abi.msg_nosignal);
    } else {
        const bytes = try args_core.getBytes(argv, 1);
        if (to != std.math.inf(f64)) ev_loop.addtimeout(to);
        return ev_stream.writeGeneric(stream, @constCast(bytes.bytes), null, ev_stream.write_mode_send, false, net_abi.msg_nosignal);
    }
}

/// `cfun_stream_send_to`, registered as `net/send-to`.
fn sendToImpl(argv: []types.Janet) raise.Raising(types.Janet) {
    try args_core.arity(argv, 3, 4);
    const stream = try getStream(argv, 0);
    try ev_loop.streamFlags(stream, stream_udpserver | stream_socket);
    const dest = try args_core.getAbstract(argv, 1, abstract_type.stored(&addressType));
    const to = try args_core.optNumber(argv, 3, std.math.inf(f64));
    if (kind.checkType(argv[2], constants.JANET_BUFFER) != 0) {
        if (to != std.math.inf(f64)) ev_loop.addtimeout(to);
        return ev_stream.writeGeneric(stream, try args_core.getBuffer(argv, 2), dest, ev_stream.write_mode_sendto, true, net_abi.msg_nosignal);
    } else {
        const bytes = try args_core.getBytes(argv, 2);
        if (to != std.math.inf(f64)) ev_loop.addtimeout(to);
        return ev_stream.writeGeneric(stream, @constCast(bytes.bytes), dest, ev_stream.write_mode_sendto, false, net_abi.msg_nosignal);
    }
}

/// `cfun_stream_flush`, registered as `net/flush`.
fn flushImpl(argv: []types.Janet) raise.Raising(types.Janet) {
    try args_core.fixarity(argv, 1);
    const stream = try getStream(argv, 0);
    try ev_loop.streamFlags(stream, stream_writable | stream_socket);
    // Toggle no delay flag, which pushes whatever Nagle's algorithm was
    // holding and then leaves the socket as it found it.
    var flag: c_int = 1;
    _ = net_abi.setSockOpt(sockOf(stream), h.IPPROTO_TCP, h.TCP_NODELAY, &flag, @sizeOf(c_int));
    flag = 0;
    _ = net_abi.setSockOpt(sockOf(stream), h.IPPROTO_TCP, h.TCP_NODELAY, &flag, @sizeOf(c_int));
    return argv[0];
}

// ==========================================================================
// Socket options
// ==========================================================================

/// `struct sockopt_type`. `kind` is a `JanetType` in the C, where
/// `JANET_POINTER` means "not one of the two simple shapes" rather than a
/// value type; the three cases are what it actually distinguishes.
const SockOpt = struct {
    name: [:0]const u8,
    level: c_int,
    optname: c_int,
    kind: enum { boolean, number, special },
};

/// `sockopt_type_list`, without its null terminator: a Zig slice carries its
/// own length, and the terminator existed to end the C loop.
const sockopt_list: []const SockOpt = blk: {
    var acc: []const SockOpt = &[_]SockOpt{
        .{ .name = "so-broadcast", .level = h.SOL_SOCKET, .optname = h.SO_BROADCAST, .kind = .boolean },
        .{ .name = "so-reuseaddr", .level = h.SOL_SOCKET, .optname = h.SO_REUSEADDR, .kind = .boolean },
        .{ .name = "so-keepalive", .level = h.SOL_SOCKET, .optname = h.SO_KEEPALIVE, .kind = .boolean },
        .{ .name = "ip-multicast-ttl", .level = h.IPPROTO_IP, .optname = h.IP_MULTICAST_TTL, .kind = .number },
        .{ .name = "ip-add-membership", .level = h.IPPROTO_IP, .optname = h.IP_ADD_MEMBERSHIP, .kind = .special },
        .{ .name = "ip-drop-membership", .level = h.IPPROTO_IP, .optname = h.IP_DROP_MEMBERSHIP, .kind = .special },
    };
    if (has_ipv6) acc = acc ++ [_]SockOpt{
        .{ .name = "ipv6-join-group", .level = h.IPPROTO_IPV6, .optname = h.IPV6_JOIN_GROUP, .kind = .special },
        .{ .name = "ipv6-leave-group", .level = h.IPPROTO_IPV6, .optname = h.IPV6_LEAVE_GROUP, .kind = .special },
        .{ .name = "ipv6-multicast-hops", .level = h.IPPROTO_IPV6, .optname = h.IPV6_MULTICAST_HOPS, .kind = .number },
        .{ .name = "ipv6-unicast-hops", .level = h.IPPROTO_IPV6, .optname = h.IPV6_UNICAST_HOPS, .kind = .number },
    };
    break :blk acc;
};

/// The `union` `cfun_net_setsockopt` builds its value in. `struct ipv6_mreq`
/// is a member on every target: it is a *system* type, and `-Dipv6=false`
/// removes Janet's options rather than the platform's headers.
const OptValue = extern union {
    v_uchar: u8,
    v_int: c_int,
    v_mreq: h.struct_ip_mreq,
    v_mreq6: h.struct_ipv6_mreq,
};

/// `cfun_net_setsockopt`, registered as `net/setsockopt`.
fn setsockoptImpl(argv: []types.Janet) raise.Raising(types.Janet) {
    try args_core.arity(argv, 3, 3);
    const stream = try getStream(argv, 0);
    try ev_loop.streamFlags(stream, stream_socket);
    const optstr = try args_core.getKeyword(argv, 1);

    var found: ?SockOpt = null;
    for (sockopt_list) |st| {
        if (utils.cstrcmp(optstr, st.name) == 0) {
            found = st;
            break;
        }
    }
    const st = found orelse return pp_format.panicf("unknown socket option %q", .{argv[1]});

    var val: OptValue = undefined;
    var optlen: usize = 0;

    switch (st.kind) {
        .boolean => {
            val.v_int = try args_core.getBoolean(argv, 2);
            optlen = @sizeOf(c_int);
        },
        .number => {
            const v_int = try args_core.getInteger(argv, 2);
            if (net_abi.multicast_ttl_char and st.optname == h.IP_MULTICAST_TTL) {
                val.v_uchar = @truncate(@as(u32, @bitCast(v_int)));
                optlen = @sizeOf(u8);
            } else {
                val.v_int = v_int;
                optlen = @sizeOf(c_int);
            }
        },
        .special => {
            if (st.optname == h.IP_ADD_MEMBERSHIP or st.optname == h.IP_DROP_MEMBERSHIP) {
                const address = try args_core.getCString(argv, 2);
                val.v_mreq = std.mem.zeroes(h.struct_ip_mreq);
                net_abi.inAddrBits(&val.v_mreq.imr_interface).* = net_abi.htonl(h.INADDR_ANY);
                _ = h.inet_pton(h.AF_INET, address, net_abi.inAddrBits(&val.v_mreq.imr_multiaddr));
                optlen = @sizeOf(h.struct_ip_mreq);
            } else if (has_ipv6 and
                (st.optname == h.IPV6_JOIN_GROUP or st.optname == h.IPV6_LEAVE_GROUP))
            {
                const address = try args_core.getCString(argv, 2);
                val.v_mreq6 = std.mem.zeroes(h.struct_ipv6_mreq);
                val.v_mreq6.ipv6mr_interface = 0;
                _ = h.inet_pton(h.AF_INET6, address, &val.v_mreq6.ipv6mr_multiaddr);
                optlen = @sizeOf(h.struct_ipv6_mreq);
            } else {
                return raise.panic("invalid socket option type");
            }
        },
    }

    assert(@src(), optlen != 0, "invalid socket option value");

    if (net_abi.setSockOpt(sockOf(stream), st.level, st.optname, &val, optlen) == -1) {
        return pp_format.panicf("setsockopt(%q): %s", .{ argv[1], janet_strerror(errno()) });
    }

    return wrap.fromNil();
}

// ==========================================================================
// Registration
// ==========================================================================

/// `net_stream_methods`. The order is the C original's, and it is the
/// contract: `janet_getmethod` walks the table linearly and `(next stream)`
/// reports it as written.
const net_stream_methods = [_]method_type.Method{
    .{ .name = "chunk", .cfun = &chunkImpl },
    .{ .name = "close", .cfun = &ev_stream.cfunStreamClose },
    .{ .name = "read", .cfun = &readImpl },
    .{ .name = "write", .cfun = &writeImpl },
    .{ .name = "flush", .cfun = &flushImpl },
    .{ .name = "accept", .cfun = &acceptImpl },
    .{ .name = "accept-loop", .cfun = &acceptLoopImpl },
    .{ .name = "send-to", .cfun = &sendToImpl },
    .{ .name = "recv-from", .cfun = &recvFromImpl },
    .{ .name = "evread", .cfun = &ev_stream.cfunStreamRead },
    .{ .name = "evchunk", .cfun = &ev_stream.cfunStreamChunk },
    .{ .name = "evwrite", .cfun = &ev_stream.cfunStreamWrite },
    .{ .name = "shutdown", .cfun = &shutdownImpl },
    .{ .name = "setsockopt", .cfun = &setsockoptImpl },
    .{ .name = null, .cfun = null },
};

/// `janet_lib_net`. The order is the C original's exactly.
pub fn libNet(env: *types.JanetTable) void {
    const table = comptime [_]corefn.Entry{
        corefn.reg("net/address", &sockaddrImpl, @src(), "(net/address host port &opt type multi)", "Look up the connection information for a given hostname, port, and connection type. Returns " ++
            "a handle that can be used to send datagrams over network without establishing a connection. " ++
            "On Posix platforms, you can use :unix for host to connect to a unix domain socket, where the name is " ++
            "given in the port argument. On Linux, abstract " ++
            "unix domain sockets are specified with a leading '@' character in port. If `multi` is truthy, will " ++
            "return all address that match in an array instead of just the first."),
        corefn.reg("net/listen", &listenImpl, @src(), "(net/listen host port &opt type no-reuse)", "Creates a server. Returns a new stream that is neither readable nor " ++
            "writeable. Use net/accept or net/accept-loop be to handle connections and start the server. " ++
            "The type parameter specifies the type of network connection, either " ++
            "a :stream (usually tcp), or :datagram (usually udp). If not specified, the default is " ++
            ":stream. The host and port arguments are the same as in net/address. The last boolean parameter `no-reuse` will " ++
            "disable the use of `SO_REUSEADDR` and `SO_REUSEPORT` when creating a server on some operating systems."),
        corefn.reg("net/socket", &socketImpl, @src(), "(net/socket &opt type address-family)", "Creates a new unbound socket. Type is an optional keyword, " ++
            "either a :stream (usually tcp), or :datagram (usually udp). The default is :stream. " ++
            "`address-family` should be one of :ipv4 or :ipv6."),
        corefn.reg("net/accept", &acceptImpl, @src(), "(net/accept stream &opt timeout)", "Get the next connection on a server stream. This would usually be called in a loop in a dedicated fiber. " ++
            "Takes an optional timeout in seconds, after which will raise an error. " ++
            "Returns a new duplex stream which represents a connection to the client."),
        corefn.reg("net/accept-loop", &acceptLoopImpl, @src(), "(net/accept-loop stream handler)", "Shorthand for running a server stream that will continuously accept new connections. " ++
            "Blocks the current fiber until the stream is closed, and will return the stream."),
        corefn.reg("net/read", &readImpl, @src(), "(net/read stream nbytes &opt buf timeout)", "Read up to n bytes from a stream, suspending the current fiber until the bytes are available. " ++
            "`n` can also be the keyword `:all` to read into the buffer until end of stream. " ++
            "If less than n bytes are available (and more than 0), will push those bytes and return early. " ++
            "Takes an optional timeout in seconds, after which will raise an error. " ++
            "Returns a buffer with up to n more bytes in it, or raises an error if the read failed."),
        corefn.reg("net/chunk", &chunkImpl, @src(), "(net/chunk stream nbytes &opt buf timeout)", "Same a net/read, but will wait for all n bytes to arrive rather than return early. " ++
            "Takes an optional timeout in seconds, after which will raise an error."),
        corefn.reg("net/write", &writeImpl, @src(), "(net/write stream data &opt timeout)", "Write data to a stream, suspending the current fiber until the write " ++
            "completes. Takes an optional timeout in seconds, after which will raise an error. " ++
            "Returns nil, or raises an error if the write failed."),
        corefn.reg("net/send-to", &sendToImpl, @src(), "(net/send-to stream dest data &opt timeout)", "Writes a datagram to a server stream. dest is a the destination address of the packet. " ++
            "Takes an optional timeout in seconds, after which will raise an error. " ++
            "Returns stream."),
        corefn.reg("net/recv-from", &recvFromImpl, @src(), "(net/recv-from stream nbytes buf &opt timeout)", "Receives data from a server stream and puts it into a buffer. Returns the socket-address the " ++
            "packet came from. Takes an optional timeout in seconds, after which will raise an error."),
        corefn.reg("net/flush", &flushImpl, @src(), "(net/flush stream)", "Make sure that a stream is not buffering any data. This temporarily disables Nagle's algorithm. " ++
            "Use this to make sure data is sent without delay. Returns stream."),
        corefn.reg("net/connect", &connectImpl, @src(), "(net/connect host port &opt type bindhost bindport)", "Open a connection to communicate with a server. Returns a duplex stream " ++
            "that can be used to communicate with the server. Type is an optional keyword " ++
            "to specify a connection type, either :stream or :datagram. The default is :stream. " ++
            "Bindhost is an optional string to select from what address to make the outgoing " ++
            "connection, with the default being the same as using the OS's preferred address. "),
        corefn.reg("net/shutdown", &shutdownImpl, @src(), "(net/shutdown stream &opt mode)", "Stop communication on this socket in a graceful manner, either in both directions or just " ++
            "reading/writing from the stream. The `mode` parameter controls which communication to stop on the socket. " ++
            "\n\n* `:wr` is the default and prevents both reading new data from the socket and writing new data to the socket.\n" ++
            "* `:r` disables reading new data from the socket.\n" ++
            "* `:w` disable writing data to the socket.\n\n" ++
            "Returns the original socket."),
        corefn.reg("net/peername", &getpeernameImpl, @src(), "(net/peername stream)", "Gets the remote peer's address and port in a tuple in that order."),
        corefn.reg("net/localname", &getsocknameImpl, @src(), "(net/localname stream)", "Gets the local address and port in a tuple in that order."),
        corefn.reg("net/address-unpack", &addressUnpackImpl, @src(), "(net/address-unpack address)", "Given an address returned by net/address, return a host, port pair. Unix domain sockets " ++
            "will have only the path in the returned tuple."),
        corefn.reg("net/setsockopt", &setsockoptImpl, @src(), "(net/setsockopt stream option value)", "set socket options.\n" ++
            "\n" ++
            "supported options and associated value types:\n" ++
            "- :so-broadcast boolean\n" ++
            "- :so-reuseaddr boolean\n" ++
            "- :so-keepalive boolean\n" ++
            "- :ip-multicast-ttl number\n" ++
            "- :ip-add-membership string\n" ++
            "- :ip-drop-membership string\n" ++
            "- :ipv6-join-group string\n" ++
            "- :ipv6-leave-group string\n" ++
            "- :ipv6-multicast-hops number\n" ++
            "- :ipv6-unicast-hops number\n"),
        corefn.end,
    };
    corefn.install(env, &table);
}

/// `janet_net_init`. Winsock has to be started before any socket call, and
/// the `ConnectEx` pointer is per-VM rather than per-process.
pub fn netInit() void {
    if (windows) {
        var wsa_data: h.WSADATA = undefined;
        // `MAKEWORD(2, 2)`, which is a macro and does not survive translation.
        assert(@src(), h.WSAStartup(0x0202, &wsa_data) == 0, "could not start winsock");
        vm().connect_ex_loaded = 0;
        vm().connect_ex = null;
    }
}

/// `janet_net_deinit`.
pub fn netDeinit() void {
    if (windows) {
        _ = h.WSACleanup();
    }
}

// -------------------------------------------------------------------------
// Addresses -- what `net_addr.zig` was.
// -------------------------------------------------------------------------

const has_ipv6 = net_abi.has_ipv6;
const SockLen = net_abi.SockLen;

/// `janet_address_type`. `JANET_ATEND_NAME` leaves every callback null, and
/// the translated structure defaults each field to null, so the name is the
/// whole definition.
pub const addressType: abstract_type.AbstractType = .{
    .name = "core/socket-address",
};

// ==========================================================================
// The two keyword vocabularies
// ==========================================================================

/// `net_get_address_family`. An unrecognised keyword is `AF_UNSPEC` rather
/// than an error, which is `net.c`'s behaviour whether or not it was its
/// intention.
pub fn addressFamily(x: types.Janet) c_int {
    if (kind.checkType(x, constants.JANET_NIL) != 0) return h.AF_UNSPEC;
    if (args_core.keyeq(x, "ipv4") != 0) return h.AF_INET;
    if (args_core.keyeq(x, "ipv6") != 0) return h.AF_INET6;
    if (!windows) {
        if (args_core.keyeq(x, "unix") != 0) return h.AF_UNIX;
    }
    return h.AF_UNSPEC;
}

/// `janet_get_sockettype`.
pub fn socketType(argv: []types.Janet, n: i32) raise.Raising(c_int) {
    const stype = try args_core.optKeyword(argv, n, null);
    if (stype == null or utils.cstrcmp(stype.?, "stream") == 0) return h.SOCK_STREAM;
    if (utils.cstrcmp(stype.?, "datagram") != 0) {
        return pp_format.panicf("expected socket type as :stream or :datagram, got %v", .{argv[@intCast(n)]});
    }
    return h.SOCK_DGRAM;
}

// ==========================================================================
// `getaddrinfo`
// ==========================================================================

/// What `janet_get_addrinfo` returns.
///
/// The C signature is one pointer plus two out-parameters, and the pointer is
/// a `struct addrinfo *` or a `struct sockaddr_un *` depending on one of them
/// -- which is why the C has to remember, at each of the seven places it
/// releases one, which allocator it came from. Carrying the discriminant with
/// the pointer is the same information in a shape the compiler checks. It is
/// also the shape that makes `FOUND.md`'s leak visible as a missing call
/// rather than as a `janet_free` that looks like every other one.
pub const AddrInfo = struct {
    /// The `getaddrinfo` chain, or null for a unix domain address. It may also
    /// be null after a *successful* lookup that matched nothing, which is what
    /// `net/address` raises "no data for given address" on.
    ai: ?*h.struct_addrinfo = null,
    /// The `janet_calloc`ed unix domain address, or null.
    un: ?*net_abi.SockAddrUn = null,
    /// `*sizeout`: the address length `bind` and `connect` are given. That is
    /// the real length for a unix domain address, and otherwise the size of
    /// the largest one -- 0 on Windows, which has none.
    size: SockLen = 0,

    pub fn isUnix(self: AddrInfo) bool {
        return self.un != null;
    }

    /// `freeaddrinfo` or `janet_free`, whichever this one needs. Note that
    /// `freeaddrinfo(NULL)` is reached when a lookup succeeds and matches
    /// nothing, which is what `net.c` does too.
    pub fn free(self: AddrInfo) void {
        if (self.un) |p| {
            utils.free(p);
        } else {
            h.freeaddrinfo(self.ai);
        }
    }
};

/// `janet_get_addrinfo`. Needs `argc >= offset + 2`.
pub fn getAddrInfo(
    argv: []types.Janet,
    offset: i32,
    socktype: c_int,
    passive: bool,
) raise.Raising(AddrInfo) {
    // Unix socket support - not yet supported on windows.
    if (!windows) {
        if (args_core.keyeq(argv[@intCast(offset)], "unix") != 0) {
            const path = try args_core.getCString(argv, offset + 1);
            const saddr: *net_abi.SockAddrUn = @ptrCast(@alignCast(
                utils.calloc(1, @sizeOf(net_abi.SockAddrUn)) orelse outOfMemory(@src()),
            ));
            saddr.sun_family = h.AF_UNIX;
            // `snprintf(saddr->sun_path, path_size, "%s", path)`: a copy that
            // truncates and always terminates.
            const room = saddr.sun_path.len - 1;
            const taken = @min(room, std.mem.len(path));
            @memcpy(saddr.sun_path[0..taken], path[0..taken]);
            saddr.sun_path[taken] = 0;
            var size: SockLen = @sizeOf(net_abi.SockAddrUn);
            if (builtin.os.tag == .linux) {
                // An abstract address: the name starts at a NUL, and the
                // length is exactly what was written rather than the whole
                // structure.
                if (path[0] == '@') {
                    saddr.sun_path[0] = 0;
                    size = @intCast(@offsetOf(net_abi.SockAddrUn, "sun_path") +
                        @as(usize, @intCast(types.stringHead(path).length)));
                }
            }
            return .{ .un = saddr, .size = size };
        }
    }

    // Get host and port.
    const host = try args_core.getCString(argv, offset);
    const port = if (args_core.checkint(argv[@intCast(offset + 1)]) != 0)
        pp_describe.toString(argv[@intCast(offset + 1)])
    else
        try args_core.optCString(argv, offset + 1, null);

    var ai: ?*h.struct_addrinfo = null;
    var hints = std.mem.zeroes(h.struct_addrinfo);
    hints.ai_family = h.AF_UNSPEC;
    hints.ai_socktype = socktype;
    hints.ai_flags = if (passive) h.AI_PASSIVE else 0;
    const status = h.getaddrinfo(host, port, &hints, &ai);
    if (status != 0) {
        return pp_format.panicf("could not get address info: %s", .{net_abi.gaiStrerror(status)});
    }
    return .{ .ai = ai, .size = if (windows) 0 else @sizeOf(net_abi.SockAddrUn) };
}

// ==========================================================================
// Decoding an address
// ==========================================================================

/// `janet_so_getname`: a socket address becomes a `(host port)` tuple, or a
/// one-element `(path)` tuple for a unix domain socket.
///
/// An `if` chain rather than a `switch` because two of the three arms are
/// conditional -- there is no `AF_INET6` without IPv6 and no
/// `struct sockaddr_un` on Windows -- and a `switch` prong cannot be compiled
/// out the way a nested comptime `if` body can.
pub fn soGetName(sa_any: ?*const anyopaque) raise.Raising(types.Janet) {
    const sa: *const h.struct_sockaddr = @ptrCast(@alignCast(sa_any));
    var buffer: [net_abi.sa_addrstrlen]u8 = undefined;
    const family: c_int = sa.sa_family;

    if (family == h.AF_INET) {
        const sai: *const h.struct_sockaddr_in = @ptrCast(@alignCast(sa_any));
        if (net_abi.inetNtop(h.AF_INET, &sai.sin_addr, &buffer, buffer.len) == null) {
            return raise.panic("unable to decode ipv4 host address");
        }
        var pair = [2]types.Janet{
            value.fromBytes(std.mem.sliceTo(&buffer, 0), .string),
            wrapInteger(net_abi.ntohs(sai.sin_port)),
        };
        return wrap.fromTuple(tuples.newFrom(&pair, 2));
    }

    if (has_ipv6) {
        if (family == h.AF_INET6) {
            const sai6: *const net_abi.SockAddrIn6 = @ptrCast(@alignCast(sa_any));
            if (net_abi.inetNtop(h.AF_INET6, &sai6.sin6_addr, &buffer, buffer.len) == null) {
                // "ipv4" is the C original's word, in its IPv6 arm. A port
                // reproduces defined behaviour; `FOUND.md` has the entry.
                return raise.panic("unable to decode ipv4 host address");
            }
            var pair = [2]types.Janet{
                value.fromBytes(std.mem.sliceTo(&buffer, 0), .string),
                wrapInteger(net_abi.ntohs(sai6.sin6_port)),
            };
            return wrap.fromTuple(tuples.newFrom(&pair, 2));
        }
    }

    if (!windows) {
        if (family == h.AF_UNIX) {
            const sun: *const net_abi.SockAddrUn = @ptrCast(@alignCast(sa_any));
            var pathname: types.Janet = undefined;
            if (sun.sun_path[0] == 0) {
                // An abstract address: the leading NUL shows as '@', and the
                // whole fixed-size path is copied because the name behind it
                // is not NUL-terminated.
                @memcpy(buffer[0..sun.sun_path.len], &sun.sun_path);
                buffer[0] = '@';
                pathname = value.fromBytes(std.mem.sliceTo(&buffer, 0), .string);
            } else {
                pathname = value.fromBytes(std.mem.sliceTo(&sun.sun_path, 0), .string);
            }
            return wrap.fromTuple(tuples.newFrom(@ptrCast(&pathname), 1));
        }
    }

    return raise.panic("unknown address family");
}

/// `janet_wrap_integer`, written out. `janet.h` declares the function beside
/// its macro and `wrap.c` defines it only for the two nanbox layouts, so a
/// tagged build has no such symbol. `ev_loop.zig` was the fifth subsystem to
/// meet this and `FOUND.md` records it.
inline fn wrapInteger(x: anytype) types.Janet {
    return wrap.fromNumber(@floatFromInt(x));
}

// ==========================================================================
// The four address cfunctions
// ==========================================================================

/// The stream type, by import. Declared `extern const` here until Phase 11
/// Part 22; the socket layer exists only where the event loop does, so there
/// was never a configuration in which the symbol was the only way to reach it.
///
/// The *module* is named rather than the constant: an alias of a `const` is a
/// copy, and `&copy` is not the address an abstract carries.
/// Copy `len` bytes of a socket address into a fresh `core/socket-address`.
fn addressAbstract(from: ?*const anyopaque, len: usize) types.Janet {
    const abst = abstracts.new(abstract_type.stored(&addressType), len);
    @memcpy(
        @as([*]u8, @ptrCast(abst))[0..len],
        @as([*]const u8, @ptrCast(from))[0..len],
    );
    return wrap.fromAbstract(abst);
}

/// `cfun_net_sockaddr`, registered as `net/address`.
pub fn sockaddrImpl(argv: []types.Janet) raise.Raising(types.Janet) {
    try vm_lifecycle.sandboxAssert(constants.JANET_SANDBOX_NET_CONNECT); // connect OR listen
    try args_core.arity(argv, 2, 4);
    const socktype = try socketType(argv, 2);
    // The guard counts to three and the subscript counts to four, so a
    // three-argument call reads a slot it was not given. `FOUND.md` has the
    // entry; the read is inside the fiber's own stack, so it is a wrong answer
    // rather than a fault, and the condition is reproduced as written.
    const make_arr = @as(i32, @intCast(argv.len)) >= 3 and kind.truthy(argv[3]) != 0;
    const info = try getAddrInfo(argv, 0, socktype, false);

    if (!windows) {
        // No unix domain socket support on windows yet. `net.c` returns from
        // here without releasing `info`, which `FOUND.md` records and this
        // reproduces.
        if (info.un) |saddr| {
            const ret = addressAbstract(saddr, @intCast(info.size));
            if (!make_arr) return ret;
            var one = [_]types.Janet{ret};
            return wrap.fromArray(arrays.newFrom(&one, 1));
        }
    }

    if (make_arr) {
        // Select all.
        const arr = arrays.new(10);
        var iter = info.ai;
        while (iter != null) : (iter = iter.?.ai_next) {
            try arrays.push(arr, addressAbstract(iter.?.ai_addr, @intCast(iter.?.ai_addrlen)));
        }
        info.free();
        return wrap.fromArray(arr);
    }

    // Select first.
    if (info.ai == null) return raise.panic("no data for given address");
    const ret = addressAbstract(info.ai.?.ai_addr, @intCast(info.ai.?.ai_addrlen));
    info.free();
    return ret;
}

/// `cfun_net_address_unpack`, registered as `net/address-unpack`.
pub fn addressUnpackImpl(argv: []types.Janet) raise.Raising(types.Janet) {
    try args_core.fixarity(argv, 1);
    return soGetName(try args_core.getAbstract(argv, 0, abstract_type.stored(&addressType)));
}

/// `cfun_net_getsockname`, registered as `net/localname`.
pub fn getsocknameImpl(argv: []types.Janet) raise.Raising(types.Janet) {
    return endpointName(argv, false);
}

/// `cfun_net_getpeername`, registered as `net/peername`.
pub fn getpeernameImpl(argv: []types.Janet) raise.Raising(types.Janet) {
    return endpointName(argv, true);
}

/// The two are the same cfunction but for the host call and one word of the
/// failure message. `net.c` writes them out twice; the duplication is not part
/// of the behaviour.
fn endpointName(argv: []types.Janet, comptime peer: bool) raise.Raising(types.Janet) {
    try args_core.fixarity(argv, 1);
    const js: *types.JanetStream = @ptrCast(@alignCast(try args_core.getAbstract(argv, 0, abstract_type.stored(&ev_stream.streamType))));
    if (js.flags & stream_closed != 0) return raise.panic("stream closed");
    var ss = std.mem.zeroes(h.struct_sockaddr_storage);
    var slen: SockLen = @sizeOf(h.struct_sockaddr_storage);
    const call = if (peer) net_abi.getpeername else net_abi.getsockname;
    if (call(sockOf(js), @ptrCast(&ss), &slen) != 0) {
        const what = if (peer) "peername" else "localname";
        return pp_format.panicf(
            "Failed to get " ++ what ++ " on %v: %V",
            .{ argv[0], ev_stream.evLasterr() },
        );
    }
    assert(@src(), slen <= @sizeOf(h.struct_sockaddr_storage), "socket address truncated");
    return soGetName(&ss);
}

/// `(JSock) stream->handle`. A `JanetHandle` is a `void *` on Windows, where a
/// `SOCKET` is an unsigned integer of the same width, and an `int` elsewhere.
pub inline fn sockOf(s: *const types.JanetStream) net_abi.JSock {
    return if (windows) @intFromPtr(s.handle) else s.handle;
}

// ==========================================================================
// The two C-preprocessor spellings this file cannot translate
// ==========================================================================

/// `JANET_OUT_OF_MEMORY`. The C macro names `__FILE__` and `__LINE__` at the
/// call site, so this names the caller's `@src()`.
pub fn outOfMemory(comptime where: std.builtin.SourceLocation) noreturn {
    const line = std.fmt.comptimePrint(
        "{s}:{d} - janet out of memory\n",
        .{ where.file, where.line },
    );
    _ = fwrite(line.ptr, 1, line.len, @ptrCast(@alignCast(stdio.err())));
    exit(1);
}

/// `janet_assert`. `io_core.zig` records what differs from the C macro: the
/// location is this file's, and an embedder's own `JANET_EXIT` override is a
/// preprocessor substitution no Zig caller can see.
pub fn assert(comptime where: std.builtin.SourceLocation, cond: bool, comptime message: []const u8) void {
    if (cond) return;
    const line = std.fmt.comptimePrint(
        "janet abort at {s}:{d}: {s}\n",
        .{ where.file, where.line, message },
    );
    _ = fwrite(line.ptr, 1, line.len, @ptrCast(@alignCast(stdio.err())));
    abort();
}

extern fn fwrite(ptr: [*]const u8, size: usize, n: usize, stream_handle: ?*types.FILE) callconv(.c) usize;
extern fn abort() callconv(.c) noreturn;
extern fn exit(status: c_int) callconv(.c) noreturn;
