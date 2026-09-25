//! The `net/` module: sockets, and the addresses they bind and connect to.
//!
//! One name, because Janet publishes one module, with `net/abi.zig` beside it
//! for the host translation.
//!
//! `host` is imported here as `platform`, because `host` is a hostname in this
//! file and that is the better claim on the name.

// ==========================================================================
// Standard library imports
// ==========================================================================

const std = @import("std");
const builtin = @import("builtin");

// ==========================================================================
// Project imports
// ==========================================================================

const abstract_type = @import("../api/abstract_type.zig");
const abstracts = @import("value/abstracts.zig");
const args_core = @import("args.zig");
const arrays = @import("value/arrays.zig");
const c = @import("cabi");
const constants = @import("constants");
const corefn = @import("corefn.zig");
const ev_loop = @import("ev.zig");
const ev_stream = @import("ev/stream.zig");
const fibers = @import("value/fibers.zig");
const functions = @import("value/functions.zig");
const gc_mark = @import("gc/mark.zig");
const method_type = @import("method_type.zig");
const net_abi = @import("net/abi.zig");
const platform = @import("host");
const pp_describe = @import("pp.zig");
const pp_format = @import("pp/format.zig");
const raise = @import("../api/raise.zig");
const repr = @import("repr");
const stdio = @import("stdio.zig");
const strings = @import("value/strings.zig");
const tables = @import("value/tables.zig");
const utils = @import("utils.zig");
const value = @import("value.zig");
const vectors = @import("value/vectors.zig");
const vm_lifecycle = @import("vm/lifecycle.zig");
const vm_state = @import("vm/state.zig");
const wrap = @import("value/helpers/wrap.zig");

/// `net/abi.zig`'s translation, and the two names this file takes from it
/// besides.
const h = net_abi.h;

const JSock = net_abi.JSock;

const windows = net_abi.windows;

// ==========================================================================
// Constants
// ==========================================================================

/// The abstract type `net/address` returns. Every callback is null, so the
/// name is the whole definition, and the payload is what `soGetName` reads: a
/// `sockaddr` allocated at the length the platform reported, which is the
/// header-plus-trailing-bytes shape an abstract's payload can take.
pub const addressType = abstract_type.define(h.struct_sockaddr, .{
    .name = "core/socket-address",
});

/// Whether this build has IPv6, which decides whether the `AF_INET6` arms are
/// compiled.
const has_ipv6 = net_abi.has_ipv6;

/// The methods reached through `(:read s ...)` and its siblings.
///
/// The order is what a program observes: `findMethod` walks the table linearly
/// and `(next stream)` reports it as written.
const net_stream_methods = [_]method_type.Method{
    .{ .name = "chunk", .nfun = &nfunChunk },
    .{ .name = "close", .nfun = &ev_stream.nfunStreamClose },
    .{ .name = "read", .nfun = &nfunRead },
    .{ .name = "write", .nfun = &nfunWrite },
    .{ .name = "flush", .nfun = &nfunFlush },
    .{ .name = "accept", .nfun = &nfunAccept },
    .{ .name = "accept-loop", .nfun = &nfunAcceptLoop },
    .{ .name = "send-to", .nfun = &nfunSendTo },
    .{ .name = "recv-from", .nfun = &nfunRecvFrom },
    .{ .name = "evread", .nfun = &ev_stream.nfunStreamRead },
    .{ .name = "evchunk", .nfun = &ev_stream.nfunStreamChunk },
    .{ .name = "evwrite", .nfun = &ev_stream.nfunStreamWrite },
    .{ .name = "shutdown", .nfun = &nfunShutdown },
    .{ .name = "setsockopt", .nfun = &nfunSetsockopt },
    .{ .name = null, .nfun = null },
};

/// The three `shutdown(2)` directions, under the names each platform spells
/// them with.
const shutdown_r: c_int = if (windows) h.SD_RECEIVE else h.SHUT_RD;

const shutdown_rw: c_int = if (windows) h.SD_BOTH else h.SHUT_RDWR;

const shutdown_w: c_int = if (windows) h.SD_SEND else h.SHUT_WR;

/// The socket-option table, with no null terminator: a slice has its own
/// length.
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

/// The `ev/stream.Stream` flags this file sets and tests.
const stream_acceptable: u32 = @intCast(constants.stream_acceptable);

const stream_closed: u32 = @intCast(constants.stream_closed);

const stream_nodups: u32 = @intCast(constants.stream_nodups);

const stream_readable: u32 = @intCast(constants.stream_readable);

const stream_socket: u32 = @intCast(constants.stream_socket);

const stream_toclose: u32 = @intCast(constants.stream_toclose);

const stream_udpserver: u32 = @intCast(constants.stream_udpserver);

const stream_writable: u32 = @intCast(constants.stream_writable);

// ==========================================================================
// Aliased types
// ==========================================================================

/// `socklen_t`, under the name this file uses.
const SockLen = net_abi.SockLen;

// ==========================================================================
// Types
// ==========================================================================

/// What an address lookup gives back.
///
/// The discriminant travels with the pointer. The payload is a
/// `struct addrinfo *` or a `struct sockaddr_un *` and the two are released by
/// different allocators, so a bare pointer plus a pair of out-parameters would
/// leave every release site to remember which it had. `free` below reads the
/// discriminant instead, and its three call sites are each a `defer`.
pub const AddrInfo = struct {
    /// The `getaddrinfo` chain, or null for a unix domain address. It may also
    /// be null after a *successful* lookup that matched nothing, which is what
    /// `net/address` raises "no data for given address" on.
    ai: ?*h.struct_addrinfo = null,
    /// The `utils.calloc`ed unix domain address, or null.
    un: ?*net_abi.SockAddrUn = null,
    /// The address length `bind` and `connect` are given. That is the real
    /// length for a unix domain address, and otherwise the size of the largest
    /// one, which is 0 on Windows, where there are none.
    size: SockLen = 0,

    pub fn isUnix(self: AddrInfo) bool {
        return self.un != null;
    }

    /// `freeaddrinfo` or `utils.free`, whichever this one needs.
    /// `freeaddrinfo(NULL)` is reached when a lookup succeeds and matches
    /// nothing, and is defined.
    pub fn free(self: AddrInfo) void {
        if (self.un) |p| {
            utils.free(p);
        } else {
            h.freeaddrinfo(self.ai);
        }
    }
};

/// The accept callback's state. The two platforms share a name and nothing
/// else: the completion port has to have an accepting socket and a buffer
/// ready before a connection arrives, so the Windows state has both, while the
/// POSIX one has only the handler function and calls `accept(2)` when the
/// descriptor says there is something to take.
const NetStateAccept = if (windows) extern struct {
    // `extern` on the Windows arm only, and for the reason the Win32 API
    // gives: the `OVERLAPPED` this opens with is handed to `AcceptEx` and read
    // back by the completion port, so the field must be first and must be
    // where the ABI says.
    overlapped: ev_stream.Overlapped,
    function: ?*functions.Function,
    lstream: ?*ev_stream.Stream,
    astream: ?*ev_stream.Stream,
    buf: [1024]u8,
} else struct {
    function: ?*functions.Function,
};

/// The connect callback's state. Only the `ConnectEx` path uses it; the POSIX
/// path passes a null state and reads everything it needs off the stream.
const NetStateConnect = struct {
    overlapped: ev_stream.Overlapped,
};

/// The `union` `net/setsockopt` builds its value in. `struct ipv6_mreq` is a
/// member on every target: it is a system type, and `-Dipv6=false` removes
/// Janet's options rather than the platform's headers.
const OptValue = extern union {
    v_uchar: u8,
    v_int: c_int,
    v_mreq: h.struct_ip_mreq,
    v_mreq6: h.struct_ipv6_mreq,
};

/// One row of the socket-option table. `kind` is a `repr.Tag`, and
/// `repr.Tag.pointer` there means "not one of the two simple shapes" rather
/// than a value type; three cases are what it distinguishes.
const SockOpt = struct {
    name: [:0]const u8,
    level: c_int,
    optname: c_int,
    kind: enum { boolean, number, special },
};

// ==========================================================================
// Public functions
// ==========================================================================

/// The address family a keyword names. An unrecognised keyword gives back
/// `AF_UNSPEC` rather than raising, which is what a program sees.
pub fn addressFamily(x: repr.Value) c_int {
    if (repr.checkType(x, repr.Tag.nil)) return h.AF_UNSPEC;
    if (args_core.keyeq(x, "ipv4")) return h.AF_INET;
    if (args_core.keyeq(x, "ipv6")) return h.AF_INET6;
    if (!windows) {
        if (args_core.keyeq(x, "unix")) return h.AF_UNIX;
    }
    return h.AF_UNSPEC;
}

/// Aborts unless `cond`, naming this file's own position.
pub fn assert(comptime where: std.builtin.SourceLocation, cond: bool, comptime message: []const u8) void {
    if (cond) return;
    const line = std.fmt.comptimePrint(
        "wattle abort at {s}:{d}: {s}\n",
        .{ where.file, where.line, message },
    );
    _ = c.fwrite(line.ptr, 1, line.len, stdio.err());
    c.abort();
}

/// `(net/address-unpack address)`.
pub fn nfunAddressUnpack(argv: []repr.Value) raise.Error!repr.Value {
    try args_core.fixarity(argv, 1);
    return soGetName(try args_core.getAbstract(anyopaque, argv, 0, &addressType));
}

/// `(net/peername stream)`.
pub fn nfunGetpeername(argv: []repr.Value) raise.Error!repr.Value {
    return endpointName(argv, true);
}

/// `(net/localname stream)`.
pub fn nfunGetsockname(argv: []repr.Value) raise.Error!repr.Value {
    return endpointName(argv, false);
}

/// `(net/address host port [type])`.
pub fn nfunSockaddr(argv: []repr.Value) raise.Error!repr.Value {
    try vm_lifecycle.sandboxAssert(vm_lifecycle.Sandbox.of(&.{"net_connect"})); // connect OR listen
    try args_core.arity(argv, 2, 4);
    const socktype = try socketType(argv, 2);
    // The guard counts to four because the subscript does. `multi` is the
    // fourth argument, so a three-argument call has not been given one and the
    // documented result is the single address; counting to three instead reads
    // a slot that is not there, which is a wrong result in C and an
    // out-of-bounds index on a slice.
    const make_arr = argv.len >= 4 and repr.truthy(argv[3]);
    const info = try getAddrInfo(argv, 0, socktype, false);
    // The unix domain arm below returns without reaching a hand-written
    // release, and the `arrays.push` in the loop after it can raise past
    // one; the `defer` covers both.
    defer info.free();

    if (!windows) {
        if (info.un) |saddr| {
            const ret = addressAbstract(saddr, @intCast(info.size));
            if (!make_arr) return ret;
            var one = [_]repr.Value{ret};
            return wrap.fromArray(arrays.newFrom(&one));
        }
    }

    if (make_arr) {
        // Select all.
        const arr = arrays.new(10);
        var iter = info.ai;
        while (iter) |node| : (iter = node.ai_next) {
            try arrays.push(arr, addressAbstract(node.ai_addr, @intCast(node.ai_addrlen)));
        }
        return wrap.fromArray(arr);
    }

    // Select first.
    const first = info.ai orelse return raise.panic("no data for given address");
    return addressAbstract(first.ai_addr, @intCast(first.ai_addrlen));
}

/// Resolves the host and port arguments at `offset`. Needs
/// `argv.len >= offset + 2`.
pub fn getAddrInfo(
    argv: []repr.Value,
    offset: usize,
    socktype: c_int,
    passive: bool,
) raise.Error!AddrInfo {
    // Unix socket support - not yet supported on windows.
    if (!windows) {
        if (args_core.keyeq(argv[offset], "unix")) {
            const path = try args_core.getCString(argv, offset + 1);
            const saddr: *net_abi.SockAddrUn = @ptrCast(@alignCast(
                utils.calloc(1, @sizeOf(net_abi.SockAddrUn)) orelse outOfMemory(@src()),
            ));
            saddr.sun_family = h.AF_UNIX;
            // A copy into `sun_path` that truncates and always terminates.
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
                        @as(usize, strings.head(path).length));
                }
            }
            return .{ .un = saddr, .size = size };
        }
    }

    // Get host and port.
    const host = try args_core.getCString(argv, offset);
    const port = if (args_core.checkint(argv[offset + 1]))
        pp_describe.toString(argv[offset + 1])
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

/// Installs the `net/` bindings, in upstream Janet's own registration order.
pub fn libNet(env: *tables.Table) void {
    const table = comptime [_]corefn.Entry{
        corefn.reg("net/address", &nfunSockaddr, @src(), "(net/address host port)\n(net/address host port type)\n(net/address host port type multi)", "Looks up the address for host, port and type, which is `:stream` or `:datagram` and defaults to `:stream`. " ++
            "Returns a socket address that can be used to send datagrams without establishing a connection. " ++
            "On Posix platforms, host can be `:unix` to name a unix domain socket, in which case the name is " ++
            "given in port. On Linux, abstract " ++
            "unix domain sockets are specified with a leading '@' character in port. If multi is truthy, " ++
            "returns an array of all the matching addresses instead of only the first."),
        corefn.reg("net/listen", &nfunListen, @src(), "(net/listen host port)\n(net/listen host port type)\n(net/listen host port type no-reuse)", "Creates a server. Returns a new stream that is neither readable nor " ++
            "writeable. Use ^net/accept or ^net/accept-loop to handle connections and start the server. " ++
            "The type parameter specifies the type of network connection, either " ++
            "`:stream` (usually tcp), or `:datagram` (usually udp). If not specified, the default is " ++
            "`:stream`. The host and port arguments are the same as in ^net/address. If no-reuse is truthy, " ++
            "the server is created without `SO_REUSEADDR` and `SO_REUSEPORT` on the operating systems that use them."),
        corefn.reg("net/socket", &nfunSocket, @src(), "(net/socket)\n(net/socket type)\n(net/socket type address-family)", "Creates a new unbound socket. Type is an optional keyword, " ++
            "either `:stream` (usually tcp), or `:datagram` (usually udp). The default is `:stream`. " ++
            "address-family is `:ipv4` or `:ipv6`, or on Posix platforms `:unix`. Any other value leaves the family unspecified."),
        corefn.reg("net/accept", &nfunAccept, @src(), "(net/accept stream)\n(net/accept stream timeout)", "Gets the next connection on a server stream. This would usually be called in a loop in a dedicated fiber. " ++
            "Takes an optional timeout in seconds, after which it raises an error. " ++
            "Returns a new duplex stream which represents a connection to the client."),
        corefn.reg("net/accept-loop", &nfunAcceptLoop, @src(), "(net/accept-loop stream f)", "Shorthand for running a server stream that will continuously accept new connections. " ++
            "Calls f, a function of exactly one parameter, in a new fiber with each accepted connection. " ++
            "Blocks the current fiber until the stream is closed, and then returns nil."),
        corefn.reg("net/read", &nfunRead, @src(), "(net/read stream n)\n(net/read stream n ds)\n(net/read stream n ds timeout)", "Reads up to n bytes from stream into ds, a buffer, suspending the current fiber until the bytes are available. " ++
            "n can also be the keyword `:all` to read until end of stream. " ++
            "If fewer than n bytes are available (and more than 0), appends those bytes and returns early. " ++
            "Takes an optional timeout in seconds, after which it raises an error. " ++
            "Returns ds, or a new buffer if ds is not given, with up to n more bytes in it. " ++
            "Returns nil if the end of the stream is reached before any byte arrives. " ++
            "Raises an error if the read failed."),
        corefn.reg("net/chunk", &nfunChunk, @src(), "(net/chunk stream n)\n(net/chunk stream n ds)\n(net/chunk stream n ds timeout)", "Same as ^net/read, but waits for all n bytes to arrive rather than returning early. " ++
            "If the end of the stream is reached first, returns the bytes collected so far, or nil if there are none. " ++
            "Takes an optional timeout in seconds, after which it raises an error."),
        corefn.reg("net/write", &nfunWrite, @src(), "(net/write stream val)\n(net/write stream val timeout)", "Writes val, a string or buffer, to stream, suspending the current fiber until the write " ++
            "completes. Takes an optional timeout in seconds, after which it raises an error. " ++
            "Returns nil, or raises an error if the write failed."),
        corefn.reg("net/send-to", &nfunSendTo, @src(), "(net/send-to stream dest val)\n(net/send-to stream dest val timeout)", "Writes a datagram containing val, a string or buffer, to stream. dest is the destination address of the packet, as returned by ^net/address. " ++
            "Takes an optional timeout in seconds, after which it raises an error. " ++
            "Returns nil."),
        corefn.reg("net/recv-from", &nfunRecvFrom, @src(), "(net/recv-from stream n ds)\n(net/recv-from stream n ds timeout)", "Receives up to n bytes from stream and appends them to ds, a buffer. Returns the socket address the " ++
            "packet came from. Takes an optional timeout in seconds, after which it raises an error."),
        corefn.reg("net/flush", &nfunFlush, @src(), "(net/flush stream)", "Makes sure that a stream is not buffering any data. This temporarily disables Nagle's algorithm. " ++
            "Use this to make sure data is sent without delay. Returns stream."),
        corefn.reg("net/connect", &nfunConnect, @src(), "(net/connect host port)\n(net/connect host port type)\n(net/connect host port type bindhost)\n(net/connect host port type bindhost bindport)", "Opens a connection to communicate with a server. Returns a duplex stream " ++
            "that can be used to communicate with the server. Type is an optional keyword " ++
            "to specify a connection type, either `:stream` or `:datagram`. The default is `:stream`. " ++
            "Bindhost and bindport are the optional address and port to make the outgoing " ++
            "connection from, with the default being the same as using the operating system's preferred address."),
        corefn.reg("net/shutdown", &nfunShutdown, @src(), "(net/shutdown stream)\n(net/shutdown stream mode)", "Stops communication on this socket in a graceful manner, either in both directions or just " ++
            "reading/writing from the stream. The mode parameter controls which communication to stop on the socket. " ++
            "\n\n* `:rw` is the default and prevents both reading new data from the socket and writing new data to the socket.\n" ++
            "* `:r` disables reading new data from the socket.\n" ++
            "* `:w` disables writing data to the socket.\n\n" ++
            "Returns the original socket."),
        corefn.reg("net/peername", &nfunGetpeername, @src(), "(net/peername stream)", "Gets the remote peer's address and port in a vector in that order."),
        corefn.reg("net/localname", &nfunGetsockname, @src(), "(net/localname stream)", "Gets the local address and port in a vector in that order."),
        corefn.reg("net/address-unpack", &nfunAddressUnpack, @src(), "(net/address-unpack address)", "Given an address returned by ^net/address, returns a vector of the host and the port. Unix domain sockets " ++
            "will have only the path in the returned vector."),
        corefn.reg("net/setsockopt", &nfunSetsockopt, @src(), "(net/setsockopt stream option value)", "Sets socket options and returns nil.\n" ++
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
    };
    corefn.install(env, table);
}

/// The Winsock teardown that pairs with `netInit`.
pub fn netDeinit() void {
    if (windows) {
        _ = h.WSACleanup();
    }
}

/// Starts Winsock, which has to happen before any socket call, and clears the
/// `ConnectEx` pointer, which is per-VM rather than per-process.
pub fn netInit() void {
    if (windows) {
        var wsa_data: h.WSADATA = undefined;
        // `MAKEWORD(2, 2)`, which is a macro and does not survive translation.
        assert(@src(), h.WSAStartup(0x0202, &wsa_data) == 0, "could not start winsock");
        vm_state.current().ev.backend.connect_ex_loaded = false;
        vm_state.current().ev.backend.connect_ex = null;
    }
}

/// Reports where the allocation failed and ends the process, naming the
/// caller's `@src()`.
pub fn outOfMemory(comptime where: std.builtin.SourceLocation) noreturn {
    const line = std.fmt.comptimePrint(
        "{s}:{d} - wattle out of memory\n",
        .{ where.file, where.line },
    );
    _ = c.fwrite(line.ptr, 1, line.len, stdio.err());
    // Flushed here rather than left to `exit`. A report that reaches the
    // stream and not the file is a report a later reader takes for silence,
    // and silence is what this one is read against.
    _ = c.fflush(stdio.err());
    c.exit(1);
}

/// A socket address as a `(host port)` tuple, or a one-element `(path)` tuple
/// for a unix domain socket.
///
/// An `if` chain rather than a `switch` because two of the three arms are
/// conditional, since there is no `AF_INET6` without IPv6 and no
/// `struct sockaddr_un` on Windows, and a `switch` prong cannot be compiled
/// out the way a nested comptime `if` body can.
pub fn soGetName(sa_any: ?*const anyopaque) raise.Error!repr.Value {
    const sa: *const h.struct_sockaddr = @ptrCast(@alignCast(sa_any));
    var buffer: [net_abi.sa_addrstrlen]u8 = undefined;
    const family: c_int = sa.sa_family;

    if (family == h.AF_INET) {
        const sai: *const h.struct_sockaddr_in = @ptrCast(@alignCast(sa_any));
        if (net_abi.inetNtop(h.AF_INET, &sai.sin_addr, &buffer, buffer.len) == null) {
            return raise.panic("unable to decode ipv4 host address");
        }
        var pair = [2]repr.Value{
            value.fromBytes(std.mem.sliceTo(&buffer, 0), .string),
            wrap.fromInteger(net_abi.ntohs(sai.sin_port)),
        };
        return wrap.fromVector(vectors.fromSlice(&pair));
    }

    if (has_ipv6) {
        if (family == h.AF_INET6) {
            const sai6: *const net_abi.SockAddrIn6 = @ptrCast(@alignCast(sa_any));
            if (net_abi.inetNtop(h.AF_INET6, &sai6.sin6_addr, &buffer, buffer.len) == null) {
                return raise.panic("unable to decode ipv6 host address");
            }
            var pair = [2]repr.Value{
                value.fromBytes(std.mem.sliceTo(&buffer, 0), .string),
                wrap.fromInteger(net_abi.ntohs(sai6.sin6_port)),
            };
            return wrap.fromVector(vectors.fromSlice(&pair));
        }
    }

    if (!windows) {
        if (family == h.AF_UNIX) {
            const sun: *const net_abi.SockAddrUn = @ptrCast(@alignCast(sa_any));
            var pathname: repr.Value = undefined;
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
            return wrap.fromVector(vectors.fromSlice(@as(*const [1]repr.Value, &pathname)));
        }
    }

    return raise.panic("unknown address family");
}

/// A stream's handle as a socket. `platform.Handle` is a `void *` on Windows,
/// where a `SOCKET` is an unsigned integer of the same width, and an `int`
/// elsewhere.
pub inline fn sockOf(s: *const ev_stream.Stream) net_abi.JSock {
    return if (windows) @intFromPtr(s.handle) else s.handle;
}

/// The optional `type` argument the socket nfunctions share: `:stream` or
/// `:datagram`.
pub fn socketType(argv: []repr.Value, n: usize) raise.Error!c_int {
    const stype = try args_core.optKeyword(argv, n, null);
    // An absent type is `:stream`, and its arm is the fallthrough below
    // rather than the first test.
    if (stype) |wanted| {
        if (utils.cstrcmp(wanted, "stream") != 0) {
            if (utils.cstrcmp(wanted, "datagram") != 0) {
                return pp_format.panicf("expected socket type as :stream or :datagram, got %v", .{argv[n]});
            }
            return h.SOCK_DGRAM;
        }
    }
    return h.SOCK_STREAM;
}

// ==========================================================================
// Private functions
// ==========================================================================

/// The POSIX accept: takes the connection the descriptor says is waiting.
///
/// Raising, as `acceptWindows` beside it is. An accept callback returns
/// `raise.Error!void`, so an accept whose stream the backend refuses reports
/// `failed to accept connection` rather than going on with a null stream.
fn acceptPosix(op: *ev_stream.Operation, state: *NetStateAccept, event: ev_loop.AsyncEvent) raise.Error!void {
    if (event != constants.AsyncEvent.init and event != constants.AsyncEvent.read) return;
    const stream: *ev_stream.Stream = op.stream;
    const connfd: JSock = if (builtin.os.tag == .linux)
        net_abi.accept4(sockOf(stream), null, null, h.SOCK_CLOEXEC)
    else
        // An accepted socket does not take the listener's close-on-exec, so
        // `sockNoBlock` below sets it.
        net_abi.accept(sockOf(stream), null, null);
    if (!net_abi.sockValid(connfd)) return;

    sockNoBlock(connfd);
    const astream = try makeStream(connfd, stream_readable | stream_writable);
    const streamv = wrap.fromAbstract(astream);
    if (state.function) |f| {
        // `catch unreachable` because the arity was checked where it could
        // be. `net/accept-loop` refuses any handler that cannot take exactly
        // the one argument this passes, so the constructor cannot reject it
        // here, which would be at the first connection, with no caller left to
        // tell.
        const sub_fiber = fibers.new(f, 64, (&streamv)[0..1]) catch unreachable;
        sub_fiber.supervisor_channel = op.fiber.supervisor_channel;
        ev_loop.schedule(sub_fiber, wrap.fromNil());
    } else {
        ev_loop.schedule(op.fiber, streamv);
        ev_loop.asyncEnd(op);
    }
}

/// The Windows accept: takes the connection the completion port reported.
fn acceptWindows(op: *ev_stream.Operation, state: *NetStateAccept, event: ev_loop.AsyncEvent) raise.Error!void {
    if (event != constants.AsyncEvent.complete) return;
    const astream = state.astream.?;
    if (astream.flags & stream_closed != 0) {
        try ev_loop.cancel(op.fiber, value.fromBytes("failed to accept connection", .string));
        ev_loop.asyncEnd(op);
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
        try ev_loop.cancel(op.fiber, value.fromBytes("failed to accept connection", .string));
        ev_loop.asyncEnd(op);
        return;
    }

    const streamv = wrap.fromAbstract(astream);
    if (state.function) |f| {
        // Schedule the worker, then listen again for the next connection.
        // `catch unreachable` for the reason the POSIX arm above gives:
        // `net/accept-loop` refused any handler whose arity cannot take
        // exactly this one argument.
        const sub_fiber = fibers.new(f, 64, (&streamv)[0..1]) catch unreachable;
        sub_fiber.supervisor_channel = op.fiber.supervisor_channel;
        ev_loop.schedule(sub_fiber, wrap.fromNil());
        var err: repr.Value = undefined;
        if (try schedAcceptImpl(state, op, &err)) {
            try ev_loop.cancel(op.fiber, err);
            ev_loop.asyncEnd(op);
        }
    } else {
        ev_loop.schedule(op.fiber, streamv);
        ev_loop.asyncEnd(op);
    }
}

/// Copies `len` bytes of a socket address into a fresh `core/socket-address`.
fn addressAbstract(from: ?*const anyopaque, len: usize) repr.Value {
    const abst = abstracts.newBytes(&addressType, len);
    @memcpy(
        @as([*]u8, @ptrCast(abst))[0..len],
        @as([*]const u8, @ptrCast(from))[0..len],
    );
    return wrap.fromAbstract(abst);
}

/// Binds `sock` to the wildcard address of `family` on port 0, reporting
/// whether the bind succeeded.
///
/// `family` is `AF_INET` or `AF_INET6`, and any other family reports false
/// without a call. A zeroed `sockaddr` of either family is already the
/// wildcard address on port 0, so only the family field is written.
/// `nfunConnect` calls this on Windows, where `ConnectEx` requires a bound
/// socket. This function cannot raise.
fn bindWildcard(sock: JSock, family: c_int) bool {
    if (family == h.AF_INET) {
        var sin = std.mem.zeroes(h.struct_sockaddr_in);
        sin.sin_family = @intCast(family);
        return net_abi.bind(sock, @ptrCast(&sin), @sizeOf(h.struct_sockaddr_in)) == 0;
    }
    if (has_ipv6) {
        if (family == h.AF_INET6) {
            var sin6 = std.mem.zeroes(net_abi.SockAddrIn6);
            sin6.sin6_family = @intCast(family);
            return net_abi.bind(sock, @ptrCast(&sin6), @sizeOf(net_abi.SockAddrIn6)) == 0;
        }
    }
    return false;
}

/// `(net/accept stream [timeout])`.
fn nfunAccept(argv: []repr.Value) raise.Error!repr.Value {
    try args_core.arity(argv, 1, 2);
    const stream = try getStream(argv, 0);
    try ev_loop.streamFlags(stream, stream_acceptable | stream_socket);
    const to = try args_core.optNumber(argv, 1, std.math.inf(f64));
    if (to != std.math.inf(f64)) ev_loop.addtimeout(to);
    return schedAccept(stream, null);
}

/// `(net/accept-loop stream handler)`.
fn nfunAcceptLoop(argv: []repr.Value) raise.Error!repr.Value {
    try args_core.fixarity(argv, 2);
    const stream = try getStream(argv, 0);
    try ev_loop.streamFlags(stream, stream_acceptable | stream_socket);
    const fun = try args_core.getFunction(argv, 1);
    // Both ends of the arity, because the handler is entered with exactly one
    // argument. Without the upper bound a handler requiring two arguments
    // reaches the accept callback, where the fiber constructor rejects the
    // single argument it is given, at the first connection, with no caller
    // left to tell. `max_arity` needs no test of its own: it is never below
    // `min_arity`.
    const def = fun.def.?;
    if (def.min_arity < 1) return raise.panic("handler function must take at least 1 argument");
    if (def.min_arity > 1) return raise.panic("handler function must take at most 1 argument");
    return schedAccept(stream, fun);
}

/// `(net/chunk stream n [buf [timeout]])`.
fn nfunChunk(argv: []repr.Value) raise.Error!repr.Value {
    try args_core.arity(argv, 2, 4);
    const stream = try getStream(argv, 0);
    try ev_loop.streamFlags(stream, stream_readable | stream_socket);
    const n = try args_core.getNat(argv, 1);
    const buffer = try args_core.optBuffer(argv, 2, 10);
    const to = try args_core.optNumber(argv, 3, std.math.inf(f64));
    if (to != std.math.inf(f64)) ev_loop.addtimeout(to);
    return ev_stream.readGeneric(stream, buffer, n, true, ev_stream.read_mode_recv, net_abi.msg_nosignal);
}

/// `(net/connect host port [type [bindhost [bindport]]])`.
fn nfunConnect(argv: []repr.Value) raise.Error!repr.Value {
    try vm_lifecycle.sandboxAssert(vm_lifecycle.Sandbox.of(&.{"net_connect"}));
    try args_core.arity(argv, 2, 5);

    // Check arguments.
    const socktype = try socketType(argv, 2);
    const bindhost = try args_core.optCString(argv, 3, null);
    const bindport = if (argv.len >= 5 and args_core.checkint(argv[4]))
        pp_describe.toString(argv[4])
    else
        try args_core.optCString(argv, 4, null);

    // Where we're connecting to.
    var info = try getAddrInfo(argv, 0, socktype, false);
    // A `defer` rather than a release before each return below, because
    // `makeStream` raises between the last of them and the connect.
    // `AddrInfo.free` picks the allocator from the discriminant: a unix domain
    // address did not come from `getaddrinfo` and is not `freeaddrinfo`'s to
    // release.
    defer info.free();
    var addrlen: SockLen = info.size;

    // Check if we're binding address.
    var binding: ?*h.struct_addrinfo = null;
    defer if (binding) |b| h.freeaddrinfo(b);
    if (bindhost != null) {
        if (info.isUnix()) {
            return raise.panic("bindhost not supported for unix domain sockets");
        }
        var hints = std.mem.zeroes(h.struct_addrinfo);
        hints.ai_family = h.AF_UNSPEC;
        hints.ai_socktype = socktype;
        hints.ai_flags = 0;
        const status = h.getaddrinfo(bindhost, bindport, &hints, &binding);
        if (status != 0) {
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
                return pp_format.panicf("could not create socket: %V", .{v});
            }
            sa = @ptrCast(@alignCast(un));
        }
    }
    if (!is_unix_socket) {
        var rp = info.ai;
        while (rp) |node| : (rp = node.ai_next) {
            sock = openSocket(node.ai_family, node.ai_socktype, node.ai_protocol);
            if (net_abi.sockValid(sock)) {
                sa = node.ai_addr;
                addrlen = @intCast(node.ai_addrlen);
                break;
            }
        }
        if (sa == null) {
            const v = ev_stream.evLasterr();
            return pp_format.panicf("could not create socket: %V", .{v});
        }
    }

    // Bind to bindhost and bindport if given.
    if (binding != null) {
        var did_bind = false;
        var rp = binding;
        while (rp) |node| : (rp = node.ai_next) {
            if (net_abi.bind(sock, node.ai_addr, @intCast(node.ai_addrlen)) == 0) {
                did_bind = true;
                break;
            }
        }
        if (!did_bind) {
            const v = ev_stream.evLasterr();
            net_abi.sockClose(sock);
            return pp_format.panicf("could not bind outgoing address: %V", .{v});
        }
    } else if (windows and socktype == h.SOCK_STREAM) {
        // `ConnectEx` below requires a bound socket and reports `WSAEINVAL`
        // for one that is not bound. `connect` binds the socket as part of
        // connecting, so no other platform reaches this. Port 0 leaves the
        // port to the host.
        if (!bindWildcard(sock, sa.?.sa_family)) {
            const v = ev_stream.evLasterr();
            net_abi.sockClose(sock);
            return pp_format.panicf("could not bind socket before connect: %V", .{v});
        }
    }

    // Wrap the socket in the stream abstract type.
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
                // The operation does not exist yet, and
                // `net_callback_connect` names it from its init event.
                // The loop cannot dequeue a completion before this fiber
                // suspends, which `schedConnect` below is what does.
                const success = connect_ex(sock, sa, @intCast(addrlen), null, 0, null, @ptrCast(&state.overlapped.as));
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
        // Set up the socket for non-blocking IO after connecting on windows.
        sockNoBlock(sock);
    } else {
        // Set up the socket for non-blocking IO before connecting.
        sockNoBlock(sock);
        status = c.retryIntr(net_abi.connect, .{ sock, sa, addrlen });
        err = c.errno();
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
        // The stream owns the handle from `makeStream` onwards, so this
        // closes it through the stream. Closing the number by hand leaves a
        // stream whose closed flag was never set with the handle still in it,
        // and the collector closes it a second time, by which point the kernel
        // may have given it to something else, such as the next `file/open`.
        try ev_loop.streamClose(stream);
        const lasterr = ev_stream.evLasterr();
        return pp_format.panicf("could not connect socket: %V", .{lasterr});
    }

    return schedConnect(stream, null);
}

/// `(net/flush stream)`.
fn nfunFlush(argv: []repr.Value) raise.Error!repr.Value {
    try args_core.fixarity(argv, 1);
    const stream = try getStream(argv, 0);
    try ev_loop.streamFlags(stream, stream_writable | stream_socket);
    // Toggle the no-delay flag, which pushes whatever Nagle's algorithm was
    // sitting on and then leaves the socket as it found it.
    var flag: c_int = 1;
    _ = net_abi.setSockOpt(sockOf(stream), h.IPPROTO_TCP, h.TCP_NODELAY, &flag, @sizeOf(c_int));
    flag = 0;
    _ = net_abi.setSockOpt(sockOf(stream), h.IPPROTO_TCP, h.TCP_NODELAY, &flag, @sizeOf(c_int));
    return argv[0];
}

/// `(net/listen host port [type [no-reuse]])`.
fn nfunListen(argv: []repr.Value) raise.Error!repr.Value {
    try vm_lifecycle.sandboxAssert(vm_lifecycle.Sandbox.of(&.{"net_listen"}));
    try args_core.arity(argv, 2, 4);

    // Get host, port, and handler.
    const socktype = try socketType(argv, 2);
    const info = try getAddrInfo(argv, 0, socktype, true);
    defer info.free();
    const reuse = !(argv.len >= 4 and repr.truthy(argv[3]));

    var sfd: JSock = net_abi.sock_default;
    var bound = false;
    if (!windows) {
        if (info.un) |un| {
            bound = true;
            sfd = h.socket(h.AF_UNIX, socktype | net_abi.sock_flags, 0);
            if (!net_abi.sockValid(sfd)) {
                return pp_format.panicf("could not create socket: %V", .{ev_stream.evLasterr()});
            }
            const serr = serverifySocket(sfd, reuse, false);
            if (serr != null or net_abi.bind(sfd, @ptrCast(un), info.size) != 0) {
                net_abi.sockClose(sfd);
                if (serr) |message| return raise.panic(message);
                return pp_format.panicf("could not bind socket: %V", .{ev_stream.evLasterr()});
            }
        }
    }
    if (!bound) {
        // Check all addrinfos in a loop for the first that we can bind to.
        var rp = info.ai;
        while (rp) |node| : (rp = node.ai_next) {
            sfd = openSocket(node.ai_family, node.ai_socktype, node.ai_protocol);
            if (!net_abi.sockValid(sfd)) continue;
            if (serverifySocket(sfd, reuse, reuse) != null) {
                net_abi.sockClose(sfd);
                continue;
            }
            if (net_abi.bind(sfd, node.ai_addr, @intCast(node.ai_addrlen)) == 0) break;
            net_abi.sockClose(sfd);
        }
        if (rp == null) return raise.panic("could not bind to any sockets");
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

/// `(net/read stream n [buf [timeout]])`.
fn nfunRead(argv: []repr.Value) raise.Error!repr.Value {
    try args_core.arity(argv, 2, 4);
    const stream = try getStream(argv, 0);
    try ev_loop.streamFlags(stream, stream_readable | stream_socket);
    const buffer = try args_core.optBuffer(argv, 2, 10);
    const to = try args_core.optNumber(argv, 3, std.math.inf(f64));
    if (args_core.keyeq(argv[1], "all")) {
        if (to != std.math.inf(f64)) ev_loop.addtimeout(to);
        return ev_stream.readGeneric(stream, buffer, std.math.maxInt(i32), true, ev_stream.read_mode_recv, net_abi.msg_nosignal);
    } else {
        const n = try args_core.getNat(argv, 1);
        if (to != std.math.inf(f64)) ev_loop.addtimeout(to);
        return ev_stream.readGeneric(stream, buffer, n, false, ev_stream.read_mode_recv, net_abi.msg_nosignal);
    }
}

/// `(net/recv-from stream n buf [timeout])`.
fn nfunRecvFrom(argv: []repr.Value) raise.Error!repr.Value {
    try args_core.arity(argv, 3, 4);
    const stream = try getStream(argv, 0);
    try ev_loop.streamFlags(stream, stream_udpserver | stream_socket);
    const n = try args_core.getNat(argv, 1);
    const buffer = try args_core.getBuffer(argv, 2);
    const to = try args_core.optNumber(argv, 3, std.math.inf(f64));
    if (to != std.math.inf(f64)) ev_loop.addtimeout(to);
    return ev_stream.readGeneric(stream, buffer, n, false, ev_stream.read_mode_recvfrom, net_abi.msg_nosignal);
}

/// `(net/send-to stream dest data [timeout])`.
fn nfunSendTo(argv: []repr.Value) raise.Error!repr.Value {
    try args_core.arity(argv, 3, 4);
    const stream = try getStream(argv, 0);
    try ev_loop.streamFlags(stream, stream_udpserver | stream_socket);
    const dest = try args_core.getAbstract(anyopaque, argv, 1, &addressType);
    const to = try args_core.optNumber(argv, 3, std.math.inf(f64));
    if (repr.checkType(argv[2], repr.Tag.buffer)) {
        if (to != std.math.inf(f64)) ev_loop.addtimeout(to);
        return ev_stream.writeGeneric(stream, try args_core.getBuffer(argv, 2), dest, ev_stream.write_mode_sendto, true, net_abi.msg_nosignal);
    } else {
        const bytes = try args_core.getBytes(argv, 2);
        if (to != std.math.inf(f64)) ev_loop.addtimeout(to);
        return ev_stream.writeGeneric(stream, @constCast(bytes.bytes), dest, ev_stream.write_mode_sendto, false, net_abi.msg_nosignal);
    }
}

/// `(net/setsockopt stream option value)`.
fn nfunSetsockopt(argv: []repr.Value) raise.Error!repr.Value {
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
            val.v_int = @intFromBool(try args_core.getBoolean(argv, 2));
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
            // The level as well as the number, because a platform may number
            // an IPv6 option the same as an IPv4 one: macOS gives
            // `IPV6_JOIN_GROUP` the number of `IP_ADD_MEMBERSHIP`.
            if (st.level == h.IPPROTO_IP and
                (st.optname == h.IP_ADD_MEMBERSHIP or st.optname == h.IP_DROP_MEMBERSHIP))
            {
                const address = try args_core.getCString(argv, 2);
                val.v_mreq = std.mem.zeroes(h.struct_ip_mreq);
                net_abi.inAddrBits(&val.v_mreq.imr_interface).* = net_abi.htonl(h.INADDR_ANY);
                _ = h.inet_pton(h.AF_INET, address, net_abi.inAddrBits(&val.v_mreq.imr_multiaddr));
                optlen = @sizeOf(h.struct_ip_mreq);
            } else if (has_ipv6 and st.level == h.IPPROTO_IPV6 and
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
        // `evLasterr` rather than `strerror`: Winsock reports through
        // `WSAGetLastError` and sets no `errno`, so `strerror` described a
        // number the call never set. Away from Windows the two are the same
        // text.
        return pp_format.panicf("setsockopt(%q): %V", .{ argv[1], ev_stream.evLasterr() });
    }

    return wrap.fromNil();
}

/// `(net/shutdown stream [mode])`.
fn nfunShutdown(argv: []repr.Value) raise.Error!repr.Value {
    try args_core.arity(argv, 1, 2);
    const stream = try getStream(argv, 0);
    try ev_loop.streamFlags(stream, stream_socket);
    var shutdown_type = shutdown_rw;
    if (argv.len == 2) {
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
        status = c.retryIntr(h.shutdown, .{ sockOf(stream), shutdown_type });
    }
    if (status != 0) {
        return pp_format.panicf("could not shutdown socket: %V", .{ev_stream.evLasterr()});
    }
    return argv[0];
}

/// `(net/socket host port [type])`.
fn nfunSocket(argv: []repr.Value) raise.Error!repr.Value {
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
    if (argv.len >= 2) hints.ai_family = addressFamily(argv[1]);
    const status = h.getaddrinfo(null, "0", &hints, &ai);
    if (status != 0) {
        return pp_format.panicf("could not get address info: %s", .{net_abi.gaiStrerror(status)});
    }

    var rp = ai;
    while (rp) |node| : (rp = node.ai_next) {
        sfd = openSocket(node.ai_family, node.ai_socktype, node.ai_protocol);
        if (net_abi.sockValid(sfd)) break;
    }
    h.freeaddrinfo(ai);

    if (!net_abi.sockValid(sfd)) {
        const v = ev_stream.evLasterr();
        return pp_format.panicf("could not create socket: %V", .{v});
    }

    // Wrap the socket in the stream abstract type.
    const udp_flag: u32 = if (socktype == h.SOCK_DGRAM) stream_udpserver else 0;
    const stream = try makeStream(sfd, stream_readable | stream_writable | udp_flag);

    // Set up the socket for non-blocking IO.
    sockNoBlock(sfd);

    return wrap.fromAbstract(stream);
}

/// `(net/write stream data [timeout])`.
fn nfunWrite(argv: []repr.Value) raise.Error!repr.Value {
    try args_core.arity(argv, 2, 3);
    const stream = try getStream(argv, 0);
    try ev_loop.streamFlags(stream, stream_writable | stream_socket);
    const to = try args_core.optNumber(argv, 2, std.math.inf(f64));
    if (repr.checkType(argv[1], repr.Tag.buffer)) {
        if (to != std.math.inf(f64)) ev_loop.addtimeout(to);
        return ev_stream.writeGeneric(stream, try args_core.getBuffer(argv, 1), null, ev_stream.write_mode_send, true, net_abi.msg_nosignal);
    } else {
        const bytes = try args_core.getBytes(argv, 1);
        if (to != std.math.inf(f64)) ev_loop.addtimeout(to);
        return ev_stream.writeGeneric(stream, @constCast(bytes.bytes), null, ev_stream.write_mode_send, false, net_abi.msg_nosignal);
    }
}

/// `(net/localname)` and `(net/peername)` are the same nfunction but for the
/// host call and one word of the failure message. `net.c` writes them out
/// twice; the duplication is not part of the behaviour.
fn endpointName(argv: []repr.Value, comptime peer: bool) raise.Error!repr.Value {
    try args_core.fixarity(argv, 1);
    const js: *ev_stream.Stream = try args_core.getAbstract(ev_stream.Stream, argv, 0, &ev_stream.streamType);
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

/// The stream argument at `argv[n]`, or a raise where it is not one.
///
/// The stream type is reached through the `ev_stream` import at the head of
/// this file rather than by symbol. The module is named rather than the
/// constant: an alias of a `const` is a copy, and `&copy` is not the address
/// an abstract is defined by.
fn getStream(argv: []const repr.Value, n: usize) raise.Error!*ev_stream.Stream {
    return try args_core.getAbstract(ev_stream.Stream, argv, n, &ev_stream.streamType);
}

/// `ConnectEx` is not exported by any import library and has to be asked for
/// by GUID, once per VM.
fn lazyGetConnectEx(sock: JSock) h.LPFN_CONNECTEX {
    if (vm_state.current().ev.backend.connect_ex_loaded) return @ptrCast(@alignCast(vm_state.current().ev.backend.connect_ex));
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
    vm_state.current().ev.backend.connect_ex = if (success != 0) null else @ptrCast(@constCast(connect_ex_ptr));
    vm_state.current().ev.backend.connect_ex_loaded = true;
    return @ptrCast(@alignCast(vm_state.current().ev.backend.connect_ex));
}

/// Builds a stream over a socket and registers it with the event loop.
///
/// Every socket this file produces has `constants.stream_nodups` set,
/// which is what lets `ev/stream.zig`'s `streamClose` skip the unregister:
/// nothing has duplicated the descriptor, so closing it removes it from the
/// poll set for free.
///
/// Raising, and it must be: `registerStream` refuses a descriptor the backend
/// will not take, and every caller below is inside a raise-capable function,
/// the four nfunctions and both halves of the accept callback, because
/// `ev_dispatch.EVCallback` is `raise.Error!void` too. A reporting form here
/// would leave the refusal as a report nobody consumes, with a null stream
/// pointer dereferenced on top of it.
fn makeStream(handle: JSock, flags: u32) raise.Error!*ev_stream.Stream {
    const jh: platform.Handle = if (windows) @ptrFromInt(handle) else handle;
    return ev_loop.makeStream(jh, flags | stream_socket | stream_nodups, @ptrCast(&net_stream_methods));
}

/// What the loop calls when an accepting socket has a connection.
fn net_callback_accept(op: *ev_stream.Operation, event: ev_loop.AsyncEvent) raise.Error!void {
    const state: *NetStateAccept = @ptrCast(@alignCast(op.state));
    switch (event) {
        constants.AsyncEvent.mark => {
            if (windows) {
                if (state.lstream) |s| gc_mark.mark(wrap.fromAbstract(s));
                if (state.astream) |s| gc_mark.mark(wrap.fromAbstract(s));
            }
            if (state.function) |f| gc_mark.mark(wrap.fromFunction(f));
        },
        constants.AsyncEvent.close => {
            ev_loop.schedule(op.fiber, wrap.fromNil());
            ev_loop.asyncEnd(op);
        },
        constants.AsyncEvent.init => {
            if (windows) {
                // `schedAccept` issued the `AcceptEx` before this, with no
                // operation to name yet: the loop cannot dequeue a completion
                // until the fiber that called it suspends, which is after
                // this. The port owes a completion whether the call reported
                // `WSA_IO_PENDING` or finished where it stood.
                state.overlapped.op = op;
                ev_loop.asyncInFlight(op);
            } else {
                try acceptPosix(op, state, event);
            }
        },
        else => {
            if (windows) {
                try acceptWindows(op, state, event);
            } else {
                try acceptPosix(op, state, event);
            }
        },
    }
}

/// What the loop calls when a connect completes.
///
/// On Windows the result comes from the completion event for the `ConnectEx`
/// that `nfunConnect` started. Elsewhere it comes from `SO_ERROR` after a
/// writability event on a non-blocking `connect`. The two arms share only the
/// event dispatch.
fn net_callback_connect(op: *ev_stream.Operation, event: ev_loop.AsyncEvent) raise.Error!void {
    const stream: *ev_stream.Stream = op.stream;
    switch (event) {
        // `nfunConnect` issued the `ConnectEx` before this, so the port owes
        // a completion for it and the flag is what leaves the state for that
        // completion. A state is what distinguishes that path: the blocking
        // fallback this file keeps, and every other platform, schedule with
        // none and have no overlapped transfer outstanding.
        constants.AsyncEvent.init => {
            if (op.state) |state| {
                if (windows) {
                    const connect: *NetStateConnect = @ptrCast(@alignCast(state));
                    connect.overlapped.op = op;
                }
                ev_loop.asyncInFlight(op);
            }
            return;
        },
        // Neither of these two has a result to read. `NetStateConnect` holds
        // an `OVERLAPPED` alone, and the fiber in its header is the one the
        // collector is tracing to reach this callback, so `mark` has nothing
        // to trace.
        constants.AsyncEvent.mark,
        constants.AsyncEvent.deinit,
        => return,
        constants.AsyncEvent.close => {
            try ev_loop.cancel(op.fiber, value.fromBytes("stream closed", .string));
            ev_loop.asyncEnd(op);
            return;
        },
        else => {},
    }

    if (windows) {
        switch (event) {
            constants.AsyncEvent.complete => {
                // `ConnectEx` does not set the socket's connected state.
                // Until `SO_UPDATE_CONNECT_CONTEXT` is set, `getpeername`,
                // `shutdown` and the other calls that read that state fail.
                // The option takes no value, so the length is zero and the
                // pointer is not read.
                const unused: c_int = 0;
                _ = net_abi.setSockOpt(sockOf(stream), h.SOL_SOCKET, h.SO_UPDATE_CONNECT_CONTEXT, &unused, 0);
                ev_loop.schedule(op.fiber, wrap.fromAbstract(stream));
            },
            else => {
                // `GetQueuedCompletionStatus` set the thread's last error
                // to the failure reason, and `ev/backend.zig` calls this
                // before any other call replaces it.
                try ev_loop.cancel(op.fiber, ev_stream.evLasterr());
                stream.flags |= stream_toclose;
            },
        }
        ev_loop.asyncEnd(op);
        return;
    }

    var res: c_int = 0;
    var size: SockLen = @sizeOf(c_int);
    if (net_abi.getSockOpt(sockOf(stream), h.SOL_SOCKET, h.SO_ERROR, &res, &size) == 0) {
        if (res == 0) {
            ev_loop.schedule(op.fiber, wrap.fromAbstract(stream));
        } else {
            try ev_loop.cancel(op.fiber, value.fromBytes(std.mem.span(utils.strerrorSafe(res)), .string));
            stream.flags |= stream_toclose;
        }
    } else {
        try ev_loop.cancel(op.fiber, ev_stream.evLasterr());
        stream.flags |= stream_toclose;
    }
    ev_loop.asyncEnd(op);
}

/// `socket(2)`, spelled as each platform's socket layer takes it. Windows
/// needs `WSASocketW` with `WSA_FLAG_OVERLAPPED`, because every transfer on it
/// goes through the completion port.
fn openSocket(family: c_int, socktype: c_int, protocol: c_int) JSock {
    if (windows) {
        return h.WSASocketW(family, socktype, protocol, null, 0, h.WSA_FLAG_OVERLAPPED);
    }
    return h.socket(family, socktype | net_abi.sock_flags, protocol);
}

/// Puts the calling fiber to sleep on an incoming connection.
fn schedAccept(stream: *ev_stream.Stream, fun: ?*functions.Function) raise.Error {
    const state: *NetStateAccept = @ptrCast(@alignCast(
        utils.malloc(@sizeOf(NetStateAccept)) orelse outOfMemory(@src()),
    ));
    state.* = std.mem.zeroes(NetStateAccept);
    state.function = fun;
    if (windows) {
        state.lstream = stream;
        var err: repr.Value = undefined;
        if (try schedAcceptImpl(state, null, &err)) {
            utils.free(state);
            return raise.panicv(err);
        }
    } else {
        // A handler runs on its own fiber and the listener goes straight back
        // to waiting, so the readiness has to persist rather than be consumed
        // by the edge that reported it.
        if (fun != null) try ev_loop.levelTriggeredStream(stream);
    }
    return ev_loop.asyncStart(stream, constants.AsyncMode.reading, net_callback_accept, state);
}

/// The Windows half: puts an accepting socket and a buffer in flight. True on
/// failure, with `*err` set.
fn schedAcceptImpl(state: *NetStateAccept, op: ?*ev_stream.Operation, err: *repr.Value) raise.Error!bool {
    const lsock = sockOf(state.lstream.?);
    const asock = h.WSASocketW(h.AF_INET, h.SOCK_STREAM, h.IPPROTO_TCP, null, 0, h.WSA_FLAG_OVERLAPPED);
    if (asock == h.INVALID_SOCKET) {
        err.* = ev_stream.evLasterr();
        return true;
    }
    // `try` rather than this function's `err`/`true` protocol: that protocol
    // is for a failure `ev/stream.zig`'s `evLasterr` describes, and a refused
    // registration already has its own message.
    state.astream = try makeStream(asock, stream_readable | stream_writable);
    const socksize: h.DWORD = @sizeOf(h.SOCKADDR_STORAGE) + 16;
    state.overlapped.op = op;
    if (h.AcceptEx(lsock, asock, &state.buf, 0, socksize, socksize, null, @ptrCast(&state.overlapped.as)) == 0 and
        h.WSAGetLastError() != h.WSA_IO_PENDING)
    {
        err.* = ev_stream.evLasterr();
        return true;
    }
    // A call the port accepted queues a completion whether it reported
    // `WSA_IO_PENDING` or finished where it stood, and the flag is what
    // `ev.zig`'s `asyncEnd` reads to leave the state for that completion. The
    // first call has no operation yet and `net_callback_accept` marks that
    // one from its init event.
    if (op) |waiting| ev_loop.asyncInFlight(waiting);
    return false;
}

/// Puts the calling fiber to sleep until the connect completes.
fn schedConnect(stream: *ev_stream.Stream, state: ?*anyopaque) raise.Error {
    return ev_loop.asyncStart(stream, constants.AsyncMode.writing, net_callback_connect, state);
}

/// The options a listening socket needs, and nothing unless one of them
/// failed.
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

/// Makes sure a socket does not block and is closed on exec, and on the
/// platforms that have it asks for `SO_NOSIGPIPE` so that a write to a closed
/// peer is an `EPIPE` rather than a signal.
///
/// Every result is discarded. A socket that refuses to go non-blocking is not
/// reported here and shows up later as a would-block that never arrives.
fn sockNoBlock(s: JSock) void {
    if (windows) {
        var arg: h.u_long = 1;
        _ = h.ioctlsocket(s, net_abi.fionbio, &arg);
    } else {
        _ = h.fcntl(s, h.F_SETFL, h.fcntl(s, h.F_GETFL, @as(c_int, 0)) | h.O_NONBLOCK);
        // Close-on-exec is a descriptor flag, which `F_SETFD` sets. A socket
        // made with `SOCK_CLOEXEC` has it already, and one from a plain
        // `accept` does not, so it is set for every socket.
        _ = h.fcntl(s, h.F_SETFD, h.FD_CLOEXEC);
        if (@hasDecl(h, "SO_NOSIGPIPE")) {
            const enable: c_int = 1;
            _ = net_abi.setSockOpt(s, h.SOL_SOCKET, h.SO_NOSIGPIPE, &enable, @sizeOf(c_int));
        }
    }
}
