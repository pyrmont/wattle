//! `net.c`: socket creation, the connect and accept state machines, the
//! seventeen `net/` cfunctions, the socket-option table, the stream method
//! table and `janet_lib_net`. This is Phase 10 Part 14.
//!
//! ## Two files, one object, and a third translation
//!
//! `net_addr.zig` is the other source and holds everything about an *address*:
//! the abstract type, the two keyword vocabularies, `getaddrinfo` and the
//! decoder. The split is a directed acyclic graph -- this file reaches that
//! one and nothing goes back -- so the two are modules folded into one object,
//! the shape `-Dpp` and `-Dos-surface` use, rather than the cyclic file
//! imports `-Dev-loop` needs.
//!
//! `net_abi.zig` is the third translation of host headers in the tree, after
//! `abi.zig` and `os_abi.zig`, and `net_abi.h` records why the socket headers
//! are not simply added to the shared one.
//!
//! ## What crosses the C ABI, and why this file is jump-transparent
//!
//! Everything the event loop supplies -- `janet_stream`, `janet_async_start`,
//! `janet_ev_recv` and its six neighbours, `janet_schedule`, `janet_cancel`,
//! `janet_stream_flags` -- is behind `-Dev-loop`, and Part 4's rule is that a
//! selector's seam is the C ABI. Eight of those are `JANET_NO_RETURN`: they
//! end the calling cfunction by jumping, which is how a Janet fiber suspends
//! on a transfer, and that is true under *both* arms of `-Dev-loop` because
//! the Zig arm's C face delivers the same jump. So a `net/read` frame is left
//! by a `longjmp` on the ordinary path, not only on the failing one, and this
//! file may hold nothing a skipped cleanup would strand. The marker comes off
//! in Part 17 with the third `setjmp`.
//!
//! The raises this file makes *itself* are ordinary error returns, and the
//! seventeen cfunctions each get a C-ABI face from `Face` below.

const std = @import("std");
const builtin = @import("builtin");
const abi = @import("abi");
const corefn = @import("corefn");
const net_abi = @import("net_abi");
const raise = @import("raise");
const pp_format = @import("pp_format.zig");
const addr = @import("net_addr.zig");

const c = abi.c;
const evloop = @import("evloop.zig");
const ev_stream = @import("ev_stream.zig");
const lifecycle = @import("lifecycle.zig");
const arglayer = @import("arglayer.zig");
const abstract_type = @import("abstract_type.zig");
const h = net_abi.h;
const windows = net_abi.windows;
const has_ipv6 = net_abi.has_ipv6;
const JSock = net_abi.JSock;
const SockLen = net_abi.SockLen;
const sockOf = addr.sockOf;

const stream_readable: u32 = @intCast(c.JANET_STREAM_READABLE);
const stream_writable: u32 = @intCast(c.JANET_STREAM_WRITABLE);
const stream_acceptable: u32 = @intCast(c.JANET_STREAM_ACCEPTABLE);
const stream_udpserver: u32 = @intCast(c.JANET_STREAM_UDPSERVER);
const stream_socket: u32 = @intCast(c.JANET_STREAM_SOCKET);
const stream_nodups: u32 = @intCast(c.JANET_STREAM_NODUPS);
const stream_closed: u32 = @intCast(c.JANET_STREAM_CLOSED);
const stream_toclose: u32 = @intCast(c.JANET_STREAM_TOCLOSE);

inline fn vm() *c.JanetVM {
    return &c.janet_vm;
}

inline fn errno() c_int {
    return std.c._errno().*;
}

// ==========================================================================
// The event loop's C ABI
// ==========================================================================

/// `src/core/util.h`, which `abi.zig` deliberately does not translate.
extern fn janet_strerror(e: c_int) callconv(.c) [*c]const u8;

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
/// the C face until that part, so the refusal became a report nobody consumed
/// and `raise.reported`'s `blank(*JanetStream)` — a null pointer — was
/// dereferenced on top of it.
fn makeStream(handle: JSock, flags: u32) raise.Raising(*c.JanetStream) {
    const jh: c.JanetHandle = if (windows) @ptrFromInt(handle) else handle;
    return evloop.makeStream(jh, flags | stream_socket | stream_nodups, @ptrCast(&net_stream_methods));
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
/// `ev_stream.zig` restates it: `abi.zig` does not translate that header, and
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

fn net_callback_connect(fiber: [*c]c.JanetFiber, event: c.JanetAsyncEvent) raise.Raising(void) {
    const stream: *c.JanetStream = fiber.*.ev_stream;
    switch (event) {
        // Windows does not support an async connect through this path and
        // just tries immediately; everywhere else, wait for a real event
        // before looking at the result.
        c.JANET_ASYNC_EVENT_INIT => if (!windows) return,
        c.JANET_ASYNC_EVENT_DEINIT => return,
        c.JANET_ASYNC_EVENT_CLOSE => {
            try evloop.cancel(fiber, c.janet_cstringv("stream closed"));
            c.janet_async_end(fiber);
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
            c.janet_schedule(fiber, c.janet_wrap_abstract(stream));
        } else {
            try evloop.cancel(fiber, c.janet_cstringv(janet_strerror(res)));
            stream.flags |= stream_toclose;
        }
    } else {
        try evloop.cancel(fiber, c.janet_ev_lasterr());
        stream.flags |= stream_toclose;
    }
    c.janet_async_end(fiber);
}

/// `net_sched_connect`.
fn schedConnect(stream: *c.JanetStream, state: ?*anyopaque) raise.Error {
    return evloop.asyncStart(stream, c.JANET_ASYNC_LISTEN_WRITE, net_callback_connect, state);
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
    function: ?*c.JanetFunction,
    lstream: ?*c.JanetStream,
    astream: ?*c.JanetStream,
    buf: [1024]u8,
} else extern struct {
    function: ?*c.JanetFunction,
};

fn net_callback_accept(fiber: [*c]c.JanetFiber, event: c.JanetAsyncEvent) raise.Raising(void) {
    const state: *NetStateAccept = @ptrCast(@alignCast(fiber.*.ev_state));
    switch (event) {
        c.JANET_ASYNC_EVENT_MARK => {
            if (windows) {
                if (state.lstream) |s| c.janet_mark(c.janet_wrap_abstract(s));
                if (state.astream) |s| c.janet_mark(c.janet_wrap_abstract(s));
            }
            if (state.function) |f| c.janet_mark(c.janet_wrap_function(f));
        },
        c.JANET_ASYNC_EVENT_CLOSE => {
            c.janet_schedule(fiber, c.janet_wrap_nil());
            c.janet_async_end(fiber);
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

fn acceptWindows(fiber: [*c]c.JanetFiber, state: *NetStateAccept, event: c.JanetAsyncEvent) raise.Raising(void) {
    if (event != c.JANET_ASYNC_EVENT_COMPLETE) return;
    const astream = state.astream.?;
    if (astream.flags & stream_closed != 0) {
        try evloop.cancel(fiber, c.janet_cstringv("failed to accept connection"));
        c.janet_async_end(fiber);
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
        try evloop.cancel(fiber, c.janet_cstringv("failed to accept connection"));
        c.janet_async_end(fiber);
        return;
    }

    const streamv = c.janet_wrap_abstract(astream);
    if (state.function) |f| {
        // Schedule the worker, then listen again for the next connection.
        const sub_fiber = c.janet_fiber(f, 64, 1, &streamv);
        sub_fiber.*.supervisor_channel = fiber.*.supervisor_channel;
        c.janet_schedule(sub_fiber, c.janet_wrap_nil());
        var err: c.Janet = undefined;
        if (try schedAcceptImpl(state, fiber, &err)) {
            try evloop.cancel(fiber, err);
            c.janet_async_end(fiber);
        }
    } else {
        c.janet_schedule(fiber, streamv);
        c.janet_async_end(fiber);
    }
}

/// Raising, as `acceptWindows` beside it already was. A callback in this fork
/// is `raise.Error!void`, so an accept whose stream the backend refuses
/// reports the way that function's `failed to accept connection` does rather
/// than carrying on with a null stream.
fn acceptPosix(fiber: [*c]c.JanetFiber, state: *NetStateAccept, event: c.JanetAsyncEvent) raise.Raising(void) {
    if (event != c.JANET_ASYNC_EVENT_INIT and event != c.JANET_ASYNC_EVENT_READ) return;
    const stream: *c.JanetStream = fiber.*.ev_stream;
    const connfd: JSock = if (builtin.os.tag == .linux)
        net_abi.accept4(sockOf(stream), null, null, h.SOCK_CLOEXEC)
    else
        // On BSDs, CLOEXEC should be inherited from server socket.
        net_abi.accept(sockOf(stream), null, null);
    if (!net_abi.sockValid(connfd)) return;

    sockNoBlock(connfd);
    const astream = try makeStream(connfd, stream_readable | stream_writable);
    const streamv = c.janet_wrap_abstract(astream);
    if (state.function) |f| {
        const sub_fiber = c.janet_fiber(f, 64, 1, &streamv);
        sub_fiber.*.supervisor_channel = fiber.*.supervisor_channel;
        c.janet_schedule(sub_fiber, c.janet_wrap_nil());
    } else {
        c.janet_schedule(fiber, streamv);
        c.janet_async_end(fiber);
    }
}

/// `net_sched_accept_impl`, the Windows half: put an accepting socket and a
/// buffer in flight. True on failure, with `*err` set.
fn schedAcceptImpl(state: *NetStateAccept, fiber: [*c]c.JanetFiber, err: *c.Janet) raise.Raising(bool) {
    const lsock = sockOf(state.lstream.?);
    const asock = h.WSASocketW(h.AF_INET, h.SOCK_STREAM, h.IPPROTO_TCP, null, 0, h.WSA_FLAG_OVERLAPPED);
    if (asock == h.INVALID_SOCKET) {
        err.* = c.janet_ev_lasterr();
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
            c.janet_async_in_flight(fiber);
            return false;
        }
        err.* = c.janet_ev_lasterr();
        return true;
    }
    return false;
}

/// `janet_sched_accept`.
fn schedAccept(stream: *c.JanetStream, fun: ?*c.JanetFunction) raise.Error {
    const state: *NetStateAccept = @ptrCast(@alignCast(
        c.janet_malloc(@sizeOf(NetStateAccept)) orelse addr.outOfMemory(@src()),
    ));
    state.* = std.mem.zeroes(NetStateAccept);
    state.function = fun;
    if (windows) {
        state.lstream = stream;
        var err: c.Janet = undefined;
        if (try schedAcceptImpl(state, c.janet_root_fiber(), &err)) {
            c.janet_free(state);
            return raise.panicv(err);
        }
    } else {
        // A handler runs on its own fiber and the listener goes straight back
        // to waiting, so the readiness has to persist rather than be consumed
        // by the edge that reported it.
        if (fun != null) try evloop.levelTriggeredStream(stream);
    }
    return evloop.asyncStart(stream, c.JANET_ASYNC_LISTEN_READ, net_callback_accept, state);
}

// ==========================================================================
// The cfunctions
// ==========================================================================

fn getStream(argv: [*c]const c.Janet, n: i32) raise.Raising(*c.JanetStream) {
    return @ptrCast(@alignCast(try arglayer.getAbstract(argv, n, abstract_type.stored(&ev_stream.janet_stream_type))));
}

// The stream type is reached through the `ev_stream` import at the head of
// this file. It was an `extern const janet_stream_type` here until Phase 11
// Part 22 -- declared beside an import of the very file that defines it, which
// is the same thing `ev_loop.zig` was doing.

/// `cfun_net_connect`, registered as `net/connect`.
fn connectImpl(argc: i32, argv: [*c]c.Janet) raise.Raising(c.Janet) {
    try lifecycle.sandboxAssert(c.JANET_SANDBOX_NET_CONNECT);
    try arglayer.arity(argc, 2, 5);

    // Check arguments.
    const socktype = try addr.socketType(argv, argc, 2);
    const bindhost = try arglayer.optCString(argv, argc, 3, null);
    const bindport = if (argc >= 5 and c.janet_checkint(argv[4]) != 0)
        c.janet_to_string(argv[4])
    else
        try arglayer.optCString(argv, argc, 4, null);

    // Where we're connecting to.
    var info = try addr.getAddrInfo(argv, 0, socktype, false);
    var addrlen: SockLen = info.size;

    // Check if we're binding address.
    var binding: [*c]h.struct_addrinfo = null;
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
    var sa: [*c]const h.struct_sockaddr = null;
    var is_unix_socket = false;
    if (!windows) {
        if (info.un) |un| {
            is_unix_socket = true;
            sock = h.socket(h.AF_UNIX, socktype | net_abi.sock_flags, 0);
            if (!net_abi.sockValid(sock)) {
                const v = c.janet_ev_lasterr();
                info.free();
                return pp_format.panicf("could not create socket: %V", .{v});
            }
            sa = @ptrCast(@alignCast(un));
        }
    }
    if (!is_unix_socket) {
        var rp = info.ai;
        while (rp != null) : (rp = rp.*.ai_next) {
            sock = openSocket(rp.*.ai_family, rp.*.ai_socktype, rp.*.ai_protocol);
            if (net_abi.sockValid(sock)) {
                sa = rp.*.ai_addr;
                addrlen = @intCast(rp.*.ai_addrlen);
                break;
            }
        }
        if (sa == null) {
            const v = c.janet_ev_lasterr();
            if (binding != null) h.freeaddrinfo(binding);
            info.free();
            return pp_format.panicf("could not create socket: %V", .{v});
        }
    }

    // Bind to bindhost and bindport if given.
    if (binding != null) {
        var did_bind = false;
        var rp = binding;
        while (rp != null) : (rp = rp.*.ai_next) {
            if (net_abi.bind(sock, rp.*.ai_addr, @intCast(rp.*.ai_addrlen)) == 0) {
                did_bind = true;
                break;
            }
        }
        if (!did_bind) {
            const v = c.janet_ev_lasterr();
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
                    c.janet_malloc(@sizeOf(NetStateConnect)) orelse addr.outOfMemory(@src()),
                ));
                state.* = std.mem.zeroes(NetStateConnect);
                const success = connect_ex(sock, sa, @intCast(addrlen), null, 0, null, @ptrCast(&state.overlapped.as));
                info.free();
                if (success == 0 and h.WSAGetLastError() != h.ERROR_IO_PENDING) {
                    c.janet_free(state);
                    const lasterr = c.janet_ev_lasterr();
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
        return c.janet_wrap_abstract(stream);
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
        const lasterr = c.janet_ev_lasterr();
        return pp_format.panicf("could not connect socket: %V", .{lasterr});
    }

    return schedConnect(stream, null);
}

/// `cfun_net_socket`, registered as `net/socket`.
fn socketImpl(argc: i32, argv: [*c]c.Janet) raise.Raising(c.Janet) {
    try arglayer.arity(argc, 0, 2);

    const socktype = try addr.socketType(argv, argc, 0);

    // Create socket.
    var sfd: JSock = net_abi.sock_default;
    var ai: [*c]h.struct_addrinfo = null;
    var hints = std.mem.zeroes(h.struct_addrinfo);
    hints.ai_family = h.AF_UNSPEC;
    hints.ai_socktype = socktype;
    // Explicitly prevent name resolution where the platform can say so.
    hints.ai_flags = if (@hasDecl(h, "AI_NUMERICSERV")) h.AI_NUMERICSERV else 0;
    if (argc >= 2) hints.ai_family = addr.addressFamily(argv[1]);
    const status = h.getaddrinfo(null, "0", &hints, &ai);
    if (status != 0) {
        return pp_format.panicf("could not get address info: %s", .{net_abi.gaiStrerror(status)});
    }

    var rp = ai;
    while (rp != null) : (rp = rp.*.ai_next) {
        sfd = openSocket(rp.*.ai_family, rp.*.ai_socktype, rp.*.ai_protocol);
        if (net_abi.sockValid(sfd)) break;
    }
    h.freeaddrinfo(ai);

    if (!net_abi.sockValid(sfd)) {
        const v = c.janet_ev_lasterr();
        return pp_format.panicf("could not create socket: %V", .{v});
    }

    // Wrap socket in abstract type JanetStream.
    const udp_flag: u32 = if (socktype == h.SOCK_DGRAM) stream_udpserver else 0;
    const stream = try makeStream(sfd, stream_readable | stream_writable | udp_flag);

    // Set up the socket for non-blocking IO.
    sockNoBlock(sfd);

    return c.janet_wrap_abstract(stream);
}

const shutdown_rw: c_int = if (windows) h.SD_BOTH else h.SHUT_RDWR;
const shutdown_r: c_int = if (windows) h.SD_RECEIVE else h.SHUT_RD;
const shutdown_w: c_int = if (windows) h.SD_SEND else h.SHUT_WR;

/// `cfun_net_shutdown`, registered as `net/shutdown`.
fn shutdownImpl(argc: i32, argv: [*c]c.Janet) raise.Raising(c.Janet) {
    try arglayer.arity(argc, 1, 2);
    const stream = try getStream(argv, 0);
    try evloop.streamFlags(stream, stream_socket);
    var shutdown_type = shutdown_rw;
    if (argc == 2) {
        const kw = try arglayer.getKeyword(argv, 1);
        if (c.janet_cstrcmp(kw, "rw") == 0) {
            shutdown_type = shutdown_rw;
        } else if (c.janet_cstrcmp(kw, "r") == 0) {
            shutdown_type = shutdown_r;
        } else if (c.janet_cstrcmp(kw, "w") == 0) {
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
        return pp_format.panicf("could not shutdown socket: %V", .{c.janet_ev_lasterr()});
    }
    return argv[0];
}

/// `cfun_net_listen`, registered as `net/listen`.
fn listenImpl(argc: i32, argv: [*c]c.Janet) raise.Raising(c.Janet) {
    try lifecycle.sandboxAssert(c.JANET_SANDBOX_NET_LISTEN);
    try arglayer.arity(argc, 2, 4);

    // Get host, port, and handler.
    const socktype = try addr.socketType(argv, argc, 2);
    const info = try addr.getAddrInfo(argv, 0, socktype, true);
    const reuse = !(argc >= 4 and c.janet_truthy(argv[3]) != 0);

    var sfd: JSock = net_abi.sock_default;
    var bound = false;
    if (!windows) {
        if (info.un) |un| {
            bound = true;
            sfd = h.socket(h.AF_UNIX, socktype | net_abi.sock_flags, 0);
            if (!net_abi.sockValid(sfd)) {
                info.free();
                return pp_format.panicf("could not create socket: %V", .{c.janet_ev_lasterr()});
            }
            const serr = serverifySocket(sfd, reuse, false);
            if (serr != null or net_abi.bind(sfd, @ptrCast(un), info.size) != 0) {
                net_abi.sockClose(sfd);
                info.free();
                if (serr) |message| return raise.panic(message);
                return pp_format.panicf("could not bind socket: %V", .{c.janet_ev_lasterr()});
            }
            info.free();
        }
    }
    if (!bound) {
        // Check all addrinfos in a loop for the first that we can bind to.
        var rp = info.ai;
        while (rp != null) : (rp = rp.*.ai_next) {
            sfd = openSocket(rp.*.ai_family, rp.*.ai_socktype, rp.*.ai_protocol);
            if (!net_abi.sockValid(sfd)) continue;
            if (serverifySocket(sfd, reuse, reuse) != null) {
                net_abi.sockClose(sfd);
                continue;
            }
            if (net_abi.bind(sfd, rp.*.ai_addr, @intCast(rp.*.ai_addrlen)) == 0) break;
            net_abi.sockClose(sfd);
        }
        const found = rp != null;
        info.free();
        if (!found) return raise.panic("could not bind to any sockets");
    }

    if (socktype == h.SOCK_DGRAM) {
        // Datagram server (UDP).
        return c.janet_wrap_abstract(try makeStream(sfd, stream_udpserver | stream_readable));
    }

    // Stream server (TCP).
    if (h.listen(sfd, 1024) != 0) {
        net_abi.sockClose(sfd);
        return pp_format.panicf("could not listen on file descriptor: %V", .{c.janet_ev_lasterr()});
    }
    // Put sfd on our loop.
    return c.janet_wrap_abstract(try makeStream(sfd, stream_acceptable));
}

/// `cfun_stream_accept_loop`, registered as `net/accept-loop`.
fn acceptLoopImpl(argc: i32, argv: [*c]c.Janet) raise.Raising(c.Janet) {
    try arglayer.fixarity(argc, 2);
    const stream = try getStream(argv, 0);
    try evloop.streamFlags(stream, stream_acceptable | stream_socket);
    const fun = try arglayer.getFunction(argv, 1);
    if (fun.*.def.*.min_arity < 1) return raise.panic("handler function must take at least 1 argument");
    return schedAccept(stream, fun);
}

/// `cfun_stream_accept`, registered as `net/accept`.
fn acceptImpl(argc: i32, argv: [*c]c.Janet) raise.Raising(c.Janet) {
    try arglayer.arity(argc, 1, 2);
    const stream = try getStream(argv, 0);
    try evloop.streamFlags(stream, stream_acceptable | stream_socket);
    const to = try arglayer.optNumber(argv, argc, 1, std.math.inf(f64));
    if (to != std.math.inf(f64)) c.janet_addtimeout(to);
    return schedAccept(stream, null);
}

/// `cfun_stream_read`, registered as `net/read`.
fn readImpl(argc: i32, argv: [*c]c.Janet) raise.Raising(c.Janet) {
    try arglayer.arity(argc, 2, 4);
    const stream = try getStream(argv, 0);
    try evloop.streamFlags(stream, stream_readable | stream_socket);
    const buffer = try arglayer.optBuffer(argv, argc, 2, 10);
    const to = try arglayer.optNumber(argv, argc, 3, std.math.inf(f64));
    if (c.janet_keyeq(argv[1], "all") != 0) {
        if (to != std.math.inf(f64)) c.janet_addtimeout(to);
        return ev_stream.readGeneric(stream, buffer, std.math.maxInt(i32), true, ev_stream.read_mode_recv, net_abi.msg_nosignal);
    } else {
        const n = try arglayer.getNat(argv, 1);
        if (to != std.math.inf(f64)) c.janet_addtimeout(to);
        return ev_stream.readGeneric(stream, buffer, n, false, ev_stream.read_mode_recv, net_abi.msg_nosignal);
    }
}

/// `cfun_stream_chunk`, registered as `net/chunk`.
fn chunkImpl(argc: i32, argv: [*c]c.Janet) raise.Raising(c.Janet) {
    try arglayer.arity(argc, 2, 4);
    const stream = try getStream(argv, 0);
    try evloop.streamFlags(stream, stream_readable | stream_socket);
    const n = try arglayer.getNat(argv, 1);
    const buffer = try arglayer.optBuffer(argv, argc, 2, 10);
    const to = try arglayer.optNumber(argv, argc, 3, std.math.inf(f64));
    if (to != std.math.inf(f64)) c.janet_addtimeout(to);
    return ev_stream.readGeneric(stream, buffer, n, true, ev_stream.read_mode_recv, net_abi.msg_nosignal);
}

/// `cfun_stream_recv_from`, registered as `net/recv-from`.
fn recvFromImpl(argc: i32, argv: [*c]c.Janet) raise.Raising(c.Janet) {
    try arglayer.arity(argc, 3, 4);
    const stream = try getStream(argv, 0);
    try evloop.streamFlags(stream, stream_udpserver | stream_socket);
    const n = try arglayer.getNat(argv, 1);
    const buffer = try arglayer.getBuffer(argv, 2);
    const to = try arglayer.optNumber(argv, argc, 3, std.math.inf(f64));
    if (to != std.math.inf(f64)) c.janet_addtimeout(to);
    return ev_stream.readGeneric(stream, buffer, n, false, ev_stream.read_mode_recvfrom, net_abi.msg_nosignal);
}

/// `cfun_stream_write`, registered as `net/write`.
fn writeImpl(argc: i32, argv: [*c]c.Janet) raise.Raising(c.Janet) {
    try arglayer.arity(argc, 2, 3);
    const stream = try getStream(argv, 0);
    try evloop.streamFlags(stream, stream_writable | stream_socket);
    const to = try arglayer.optNumber(argv, argc, 2, std.math.inf(f64));
    if (c.janet_checktype(argv[1], c.JANET_BUFFER) != 0) {
        if (to != std.math.inf(f64)) c.janet_addtimeout(to);
        return ev_stream.writeGeneric(stream, try arglayer.getBuffer(argv, 1), null, ev_stream.write_mode_send, true, net_abi.msg_nosignal);
    } else {
        const bytes = try arglayer.getBytes(argv, 1);
        if (to != std.math.inf(f64)) c.janet_addtimeout(to);
        return ev_stream.writeGeneric(stream, @constCast(bytes.bytes), null, ev_stream.write_mode_send, false, net_abi.msg_nosignal);
    }
}

/// `cfun_stream_send_to`, registered as `net/send-to`.
fn sendToImpl(argc: i32, argv: [*c]c.Janet) raise.Raising(c.Janet) {
    try arglayer.arity(argc, 3, 4);
    const stream = try getStream(argv, 0);
    try evloop.streamFlags(stream, stream_udpserver | stream_socket);
    const dest = try arglayer.getAbstract(argv, 1, abstract_type.stored(&addr.janet_address_type));
    const to = try arglayer.optNumber(argv, argc, 3, std.math.inf(f64));
    if (c.janet_checktype(argv[2], c.JANET_BUFFER) != 0) {
        if (to != std.math.inf(f64)) c.janet_addtimeout(to);
        return ev_stream.writeGeneric(stream, try arglayer.getBuffer(argv, 2), dest, ev_stream.write_mode_sendto, true, net_abi.msg_nosignal);
    } else {
        const bytes = try arglayer.getBytes(argv, 2);
        if (to != std.math.inf(f64)) c.janet_addtimeout(to);
        return ev_stream.writeGeneric(stream, @constCast(bytes.bytes), dest, ev_stream.write_mode_sendto, false, net_abi.msg_nosignal);
    }
}

/// `cfun_stream_flush`, registered as `net/flush`.
fn flushImpl(argc: i32, argv: [*c]c.Janet) raise.Raising(c.Janet) {
    try arglayer.fixarity(argc, 1);
    const stream = try getStream(argv, 0);
    try evloop.streamFlags(stream, stream_writable | stream_socket);
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
fn setsockoptImpl(argc: i32, argv: [*c]c.Janet) raise.Raising(c.Janet) {
    try arglayer.arity(argc, 3, 3);
    const stream = try getStream(argv, 0);
    try evloop.streamFlags(stream, stream_socket);
    const optstr = try arglayer.getKeyword(argv, 1);

    var found: ?SockOpt = null;
    for (sockopt_list) |st| {
        if (c.janet_cstrcmp(optstr, st.name) == 0) {
            found = st;
            break;
        }
    }
    const st = found orelse return pp_format.panicf("unknown socket option %q", .{argv[1]});

    var val: OptValue = undefined;
    var optlen: usize = 0;

    switch (st.kind) {
        .boolean => {
            val.v_int = try arglayer.getBoolean(argv, 2);
            optlen = @sizeOf(c_int);
        },
        .number => {
            const v_int = try arglayer.getInteger(argv, 2);
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
                const address = try arglayer.getCString(argv, 2);
                val.v_mreq = std.mem.zeroes(h.struct_ip_mreq);
                net_abi.inAddrBits(&val.v_mreq.imr_interface).* = net_abi.htonl(h.INADDR_ANY);
                _ = h.inet_pton(h.AF_INET, address, net_abi.inAddrBits(&val.v_mreq.imr_multiaddr));
                optlen = @sizeOf(h.struct_ip_mreq);
            } else if (has_ipv6 and
                (st.optname == h.IPV6_JOIN_GROUP or st.optname == h.IPV6_LEAVE_GROUP))
            {
                const address = try arglayer.getCString(argv, 2);
                val.v_mreq6 = std.mem.zeroes(h.struct_ipv6_mreq);
                val.v_mreq6.ipv6mr_interface = 0;
                _ = h.inet_pton(h.AF_INET6, address, &val.v_mreq6.ipv6mr_multiaddr);
                optlen = @sizeOf(h.struct_ipv6_mreq);
            } else {
                return raise.panic("invalid socket option type");
            }
        },
    }

    addr.assert(@src(), optlen != 0, "invalid socket option value");

    if (net_abi.setSockOpt(sockOf(stream), st.level, st.optname, &val, optlen) == -1) {
        return pp_format.panicf("setsockopt(%q): %s", .{ argv[1], janet_strerror(errno()) });
    }

    return c.janet_wrap_nil();
}

// ==========================================================================
// Registration
// ==========================================================================

/// `net_stream_methods`. The order is the C original's, and it is the
/// contract: `janet_getmethod` walks the table linearly and `(next stream)`
/// reports it as written.
const net_stream_methods = [_]corefn.Method{
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
export fn janet_lib_net(env: *c.JanetTable) callconv(.c) void {
    const table = comptime [_]corefn.Entry{
        corefn.reg("net/address", &addr.sockaddrImpl, @src(), "(net/address host port &opt type multi)", "Look up the connection information for a given hostname, port, and connection type. Returns " ++
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
        corefn.reg("net/peername", &addr.getpeernameImpl, @src(), "(net/peername stream)", "Gets the remote peer's address and port in a tuple in that order."),
        corefn.reg("net/localname", &addr.getsocknameImpl, @src(), "(net/localname stream)", "Gets the local address and port in a tuple in that order."),
        corefn.reg("net/address-unpack", &addr.addressUnpackImpl, @src(), "(net/address-unpack address)", "Given an address returned by net/address, return a host, port pair. Unix domain sockets " ++
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
export fn janet_net_init() callconv(.c) void {
    if (windows) {
        var wsa_data: h.WSADATA = undefined;
        // `MAKEWORD(2, 2)`, which is a macro and does not survive translation.
        addr.assert(@src(), h.WSAStartup(0x0202, &wsa_data) == 0, "could not start winsock");
        vm().connect_ex_loaded = 0;
        vm().connect_ex = null;
    }
}

/// `janet_net_deinit`.
export fn janet_net_deinit() callconv(.c) void {
    if (windows) {
        _ = h.WSACleanup();
    }
}
