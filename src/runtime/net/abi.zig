//! The host socket declarations `net.zig` works through.
//!
//! `net.zig` reaches them as `sys`, a namespace of C names: `sys.AF_INET`,
//! `sys.struct_addrinfo`, `sys.getaddrinfo`. Each comes from Zig's standard
//! library where the standard library declares it with the platform's value
//! or layout, and is written here where it does not. Three groups are
//! written here:
//!
//! - Winsock's functions and most of its constants. Zig 0.17's
//!   `std.os.windows.ws2_32` declares the address families, socket types,
//!   option levels and socket-address structures, and no function. Each
//!   function is declared as `host/cabi.zig` declares Winsock's, with
//!   `callconv(.winapi)` and `usize` for a `SOCKET`. `AcceptEx` is
//!   `mswsock`'s, and `gai_strerrorA` is a function of mingw's import library
//!   rather than of the DLL.
//!
//! - The values `std` gives with another platform's number. On Windows that
//!   is the `AI_*`, `IP_*` and `IPV6_*` constants, which `std.c` does not
//!   resolve there, and on Linux `IPV6_JOIN_GROUP` and `IPV6_LEAVE_GROUP`,
//!   which `std` spells as `ADD_MEMBERSHIP` and `DROP_MEMBERSHIP`.
//!
//! - What no header Zig declares has: `inet_pton`, `inet_ntop`,
//!   `struct ip_mreq`, `struct ipv6_mreq`, the address-string lengths, and
//!   Windows' `struct addrinfo` and `WSADATA`.
//!
//! The structures from `std` have `std`'s field names (`family`, `port`,
//! `addr`), and the ones written here have C's. `sys` declares a name only
//! where the platform has it: a name another platform lacks is a
//! `@compileError` that fires only when a file names it, and a file that names
//! one on a single platform tests that platform's flag first.
//!
//! The wrappers below `sys` are a second population. Winsock and the POSIX
//! headers agree on what those calls do and disagree on how they are spelled:
//! `setsockopt` takes a `char *` on one and a `void *` on the other,
//! `getaddrinfo` returns an `int` on one and `std`'s `EAI` on the other, and
//! `gai_strerror` is `gai_strerrorA` on Windows. Normalising them here keeps
//! `net.zig` free of `if (windows)` at every host call.

// ==========================================================================
// Standard library imports
// ==========================================================================

const std = @import("std");
const builtin = @import("builtin");

// ==========================================================================
// Project imports
// ==========================================================================

const config = @import("config");

// ==========================================================================
// Constants
// ==========================================================================

/// `FIONBIO`, as `winsock2.h` builds it with `_IOW('f', 126, u_long)`:
/// `IOC_IN`, the argument size masked by `IOCPARM_MASK`, the group and the
/// number.
pub const fionbio: c_long = if (windows)
    @bitCast(@as(u32, 0x80000000 | ((@sizeOf(c_ulong) & 0x7f) << 16) | ('f' << 8) | 126))
else
    0;

/// Whether this build has IPv6, from `-Dipv6`.
pub const has_ipv6 = config.ipv6;

/// Whether `serverify_socket` may ask for `SO_REUSEPORT`. Every POSIX
/// platform the runtime builds for has it, and Windows does not.
pub const has_reuseport = !windows;

/// Whether the platform has `SO_NOSIGPIPE`, which macOS and FreeBSD have and
/// Linux and Windows do not.
pub const has_so_nosigpipe = darwin or freebsd;

/// `MSG_NOSIGNAL`, or 0 on Windows, which has no such flag.
pub const msg_nosignal: c_int = if (windows) 0 else std.c.MSG.NOSIGNAL;

/// Whether an `IP_MULTICAST_TTL` value is an `unsigned char`, as FreeBSD
/// takes it. Linux, macOS and Windows take an `int`.
pub const multicast_ttl_char = freebsd;

/// `SA_ADDRSTRLEN`: the buffer `net.zig`'s `soGetName` decodes into. It is the
/// larger of the numeric-address length and the unix path length, and there
/// are no unix domain sockets on Windows.
pub const sa_addrstrlen: usize = blk: {
    const numeric: usize = if (has_ipv6) sys.INET6_ADDRSTRLEN + 1 else sys.INET_ADDRSTRLEN + 1;
    if (windows) break :blk numeric;
    const path: usize = @sizeOf(@FieldType(SockAddrUn, "path")) + 1;
    break :blk @max(numeric, path);
};

/// The value a socket field has before one is assigned. The POSIX value is 0
/// rather than -1, which is a valid descriptor; nothing reads it before
/// assigning, and a caller may depend on the number.
pub const sock_default: JSock = if (windows) sys.INVALID_SOCKET else 0;

/// `JSOCKFLAGS`: the extra `socket(2)` flags, which is `SOCK_CLOEXEC` where
/// the platform has it. macOS does not, and neither does Windows.
pub const sock_flags: c_int = if (windows or darwin) 0 else sys.SOCK_CLOEXEC;

/// Whether this target takes the Winsock arm of each call below.
pub const windows = builtin.target.os.tag == .windows;

/// `WSAID_CONNECTEX`, the GUID `WSAIoctl` looks `ConnectEx` up by.
pub const wsaid_connectex = if (windows) sys.GUID{
    .Data1 = 0x25a207b9,
    .Data2 = 0xddf3,
    .Data3 = 0x4660,
    .Data4 = .{ 0x8e, 0xe9, 0x76, 0xe5, 0x8c, 0x74, 0x06, 0x3e },
} else undefined;

/// Whether this target is macOS, whose socket layer has no `SOCK_CLOEXEC`
/// and no `accept4`.
const darwin = builtin.target.os.tag.isDarwin();

/// Whether this target is FreeBSD.
const freebsd = builtin.target.os.tag == .freebsd;

/// Whether this target is Linux, where `std` spells the IPv6 group options as
/// `ADD_MEMBERSHIP` and `DROP_MEMBERSHIP`.
const linux = builtin.target.os.tag == .linux;

// ==========================================================================
// Aliased types
// ==========================================================================

/// `JSock`: `SOCKET` on Windows and a file descriptor elsewhere.
pub const JSock = if (windows) sys.SOCKET else c_int;

/// `struct sockaddr_in6`.
pub const SockAddrIn6 = sys.struct_sockaddr_in6;

/// `struct sockaddr_un`, and an opaque stand-in where there is no such thing.
/// Windows has no unix domain sockets, and a Zig field type is analysed
/// whether or not the code around it is, so the stand-in is what lets
/// `AddrInfo` name the pointer on every target.
pub const SockAddrUn = if (windows) opaque {} else sys.struct_sockaddr_un;

/// `socklen_t`: `c_uint` on Linux, `__darwin_socklen_t` on macOS and `c_int`
/// on Windows.
pub const SockLen = sys.socklen_t;

// ==========================================================================
// Types
// ==========================================================================

/// The host socket declarations, under their C names.
///
/// A name with no meaning on the target is a `@compileError`, which fires
/// only if a file names it there.
pub const sys = struct {
    const c = std.c;
    const ws2 = std.os.windows.ws2_32;

    // Address families, socket types and option levels.

    pub const AF_INET = c.AF.INET;
    pub const AF_INET6 = c.AF.INET6;
    pub const AF_UNIX = c.AF.UNIX;
    pub const AF_UNSPEC = c.AF.UNSPEC;
    pub const SOCK_CLOEXEC = if (windows or darwin) @compileError("no SOCK_CLOEXEC") else c.SOCK.CLOEXEC;
    pub const SOCK_DGRAM = c.SOCK.DGRAM;
    pub const SOCK_STREAM = c.SOCK.STREAM;
    pub const SOL_SOCKET = c.SOL.SOCKET;
    pub const IPPROTO_IP = c.IPPROTO.IP;
    pub const IPPROTO_IPV6 = if (windows) 41 else c.IPPROTO.IPV6;
    pub const IPPROTO_TCP = c.IPPROTO.TCP;

    // Socket options.

    pub const SO_BROADCAST = c.SO.BROADCAST;
    pub const SO_ERROR = c.SO.ERROR;
    pub const SO_KEEPALIVE = c.SO.KEEPALIVE;
    pub const SO_NOSIGPIPE = if (has_so_nosigpipe) c.SO.NOSIGPIPE else @compileError("no SO_NOSIGPIPE");
    pub const SO_REUSEADDR = c.SO.REUSEADDR;
    pub const SO_REUSEPORT = if (windows) @compileError("no SO_REUSEPORT") else c.SO.REUSEPORT;
    pub const SO_UPDATE_ACCEPT_CONTEXT = if (windows) ws2.SO.UPDATE_ACCEPT_CONTEXT else @compileError("Winsock only");
    pub const SO_UPDATE_CONNECT_CONTEXT = if (windows) ws2.SO.UPDATE_CONNECT_CONTEXT else @compileError("Winsock only");
    pub const TCP_NODELAY = c.TCP.NODELAY;
    pub const IP_ADD_MEMBERSHIP = if (windows) 12 else c.IP.ADD_MEMBERSHIP;
    pub const IP_DROP_MEMBERSHIP = if (windows) 13 else c.IP.DROP_MEMBERSHIP;
    pub const IP_MULTICAST_TTL = if (windows) 10 else c.IP.MULTICAST_TTL;
    pub const IPV6_JOIN_GROUP = if (windows) 12 else if (linux) c.IPV6.ADD_MEMBERSHIP else c.IPV6.JOIN_GROUP;
    pub const IPV6_LEAVE_GROUP = if (windows) 13 else if (linux) c.IPV6.DROP_MEMBERSHIP else c.IPV6.LEAVE_GROUP;
    pub const IPV6_MULTICAST_HOPS = if (windows) 10 else c.IPV6.MULTICAST_HOPS;
    pub const IPV6_UNICAST_HOPS = if (windows) 4 else c.IPV6.UNICAST_HOPS;

    // Shutdown directions. POSIX and Winsock number them alike and name them
    // differently.

    pub const SHUT_RD = if (windows) @compileError("SD_RECEIVE on Winsock") else c.SHUT.RD;
    pub const SHUT_RDWR = if (windows) @compileError("SD_BOTH on Winsock") else c.SHUT.RDWR;
    pub const SHUT_WR = if (windows) @compileError("SD_SEND on Winsock") else c.SHUT.WR;
    pub const SD_BOTH = 2;
    pub const SD_RECEIVE = 0;
    pub const SD_SEND = 1;

    // Descriptor flags and the error `connect` reports while in progress.

    pub const EINPROGRESS = @backingInt(c.E.INPROGRESS);
    pub const F_GETFL = c.F.GETFL;
    pub const F_SETFD = c.F.SETFD;
    pub const F_SETFL = c.F.SETFL;
    pub const FD_CLOEXEC = c.FD_CLOEXEC;
    pub const O_NONBLOCK: c_int = if (windows) @compileError("no O_NONBLOCK") else @bitCast(c.O{ .NONBLOCK = true });

    // Addresses.

    pub const INADDR_ANY = 0;
    pub const INET_ADDRSTRLEN = if (windows) 22 else 16;
    pub const INET6_ADDRSTRLEN = if (windows) 65 else 46;

    // Winsock's own.

    pub const ERROR_IO_PENDING = 997;
    pub const INVALID_SOCKET: SOCKET = std.math.maxInt(SOCKET);
    pub const NO_ERROR = 0;
    pub const SIO_GET_EXTENSION_FUNCTION_POINTER: u32 = 0xc8000006;
    pub const SOCKET_ERROR = -1;
    pub const WSA_FLAG_OVERLAPPED: u32 = 0x01;
    pub const WSA_IO_PENDING = ERROR_IO_PENDING;
    pub const WSAEWOULDBLOCK = 10035;

    // Types.

    pub const DWORD = u32;
    pub const GUID = std.os.windows.GUID;
    pub const SOCKET = usize;
    pub const u_long = c_ulong;
    pub const socklen_t = if (windows) c_int else c.socklen_t;
    pub const struct_addrinfo = if (windows) WinAddrInfo else c.addrinfo;
    pub const struct_sockaddr = if (windows) ws2.sockaddr else c.sockaddr;
    pub const struct_sockaddr_in = if (windows) ws2.sockaddr.in else c.sockaddr.in;
    pub const struct_sockaddr_in6 = if (windows) ws2.sockaddr.in6 else c.sockaddr.in6;
    pub const struct_sockaddr_storage = if (windows) ws2.sockaddr.storage else c.sockaddr.storage;
    pub const struct_sockaddr_un = if (windows) @compileError("no unix domain sockets") else c.sockaddr.un;

    /// The `flags` field of `struct addrinfo`. `std` gives a packed struct on
    /// every POSIX target, and Windows' bits are the two the runtime sets.
    pub const AI = if (windows) packed struct(u32) {
        PASSIVE: bool = false,
        CANONNAME: bool = false,
        NUMERICHOST: bool = false,
        NUMERICSERV: bool = false,
        _: u28 = 0,
    } else c.AI;

    /// `struct ip_mreq`. Each address is a `struct in_addr`, four bytes in
    /// network order.
    pub const struct_ip_mreq = extern struct {
        imr_multiaddr: u32,
        imr_interface: u32,
    };

    /// `struct ipv6_mreq`. The group is a `struct in6_addr`, which has the
    /// alignment of the `u32` in its union.
    pub const struct_ipv6_mreq = extern struct {
        ipv6mr_multiaddr: [16]u8 align(4),
        ipv6mr_interface: c_uint,
    };

    /// `LPFN_CONNECTEX`, the function `WSAIoctl` returns for
    /// `WSAID_CONNECTEX`.
    pub const LPFN_CONNECTEX = ?*const fn (
        s: SOCKET,
        name: ?*const struct_sockaddr,
        namelen: c_int,
        send_buf: ?*anyopaque,
        send_len: DWORD,
        sent: ?*DWORD,
        overlapped: ?*anyopaque,
    ) callconv(.winapi) c_int;

    /// `WSADATA` as 64-bit Windows lays it out. The 32-bit layout puts the
    /// two strings before `iMaxSockets`.
    pub const WSADATA = extern struct {
        wVersion: u16,
        wHighVersion: u16,
        iMaxSockets: c_ushort,
        iMaxUdpDg: c_ushort,
        lpVendorInfo: ?[*]u8,
        szDescription: [257]u8,
        szSystemStatus: [129]u8,
    };

    /// Windows' `struct addrinfo`, whose `ai_addrlen` is a `size_t` and whose
    /// name precedes the address.
    const WinAddrInfo = extern struct {
        flags: AI,
        family: c_int,
        socktype: c_int,
        protocol: c_int,
        addrlen: usize,
        canonname: ?[*:0]u8,
        addr: ?*struct_sockaddr,
        next: ?*WinAddrInfo,
    };

    // Functions.

    pub const close = c.close;
    pub const fcntl = c.fcntl;
    pub const freeaddrinfo = if (windows) win.freeaddrinfo else c.freeaddrinfo;
    pub const inet_ntop = if (windows) win.inet_ntop else posix.inet_ntop;
    pub const inet_pton = if (windows) win.inet_pton else posix.inet_pton;
    pub const listen = if (windows) win.listen else posixListen;
    pub const shutdown = if (windows) win.shutdown else c.shutdown;
    pub const socket = if (windows) win.socket else posixSocket;

    pub const AcceptEx = win.AcceptEx;
    pub const closesocket = win.closesocket;
    pub const gai_strerrorA = win.gai_strerrorA;
    pub const ioctlsocket = win.ioctlsocket;
    pub const WSACleanup = win.WSACleanup;
    pub const WSAConnect = win.WSAConnect;
    pub const WSAGetLastError = win.WSAGetLastError;
    pub const WSAIoctl = win.WSAIoctl;
    pub const WSASocketW = win.WSASocketW;
    pub const WSAStartup = win.WSAStartup;

    /// `listen(2)`, with the `int` backlog C declares.
    fn posixListen(s: c_int, backlog: c_int) c_int {
        return c.listen(s, @bitCast(backlog));
    }

    /// `socket(2)`, with the `int` arguments C declares.
    fn posixSocket(domain: c_int, kind: c_int, protocol: c_int) c_int {
        return c.socket(@bitCast(domain), @bitCast(kind), @bitCast(protocol));
    }

    /// The two address-string calls, which `std.c` does not declare.
    pub const posix = struct {
        pub extern "c" fn inet_ntop(af: c_int, src: *const anyopaque, dst: [*]u8, size: socklen_t) ?[*:0]const u8;
        pub extern "c" fn inet_pton(af: c_int, src: [*:0]const u8, dst: *anyopaque) c_int;
    };

    /// Winsock's functions, which `std.os.windows.ws2_32` does not declare.
    pub const win = struct {
        pub extern "ws2_32" fn accept(s: SOCKET, addr: ?*struct_sockaddr, addrlen: ?*c_int) callconv(.winapi) SOCKET;
        pub extern "ws2_32" fn bind(s: SOCKET, name: ?*const struct_sockaddr, namelen: c_int) callconv(.winapi) c_int;
        pub extern "ws2_32" fn closesocket(s: SOCKET) callconv(.winapi) c_int;
        pub extern "ws2_32" fn connect(s: SOCKET, name: ?*const struct_sockaddr, namelen: c_int) callconv(.winapi) c_int;
        pub extern "ws2_32" fn freeaddrinfo(ai: ?*WinAddrInfo) callconv(.winapi) void;
        pub extern "ws2_32" fn getaddrinfo(node: ?[*:0]const u8, service: ?[*:0]const u8, hints: ?*const WinAddrInfo, res: *?*WinAddrInfo) callconv(.winapi) c_int;
        pub extern "ws2_32" fn getpeername(s: SOCKET, name: *struct_sockaddr, namelen: *c_int) callconv(.winapi) c_int;
        pub extern "ws2_32" fn getsockname(s: SOCKET, name: *struct_sockaddr, namelen: *c_int) callconv(.winapi) c_int;
        pub extern "ws2_32" fn getsockopt(s: SOCKET, level: c_int, optname: c_int, optval: [*]u8, optlen: *c_int) callconv(.winapi) c_int;
        pub extern "ws2_32" fn inet_ntop(af: c_int, src: *const anyopaque, dst: [*]u8, size: usize) callconv(.winapi) ?[*:0]const u8;
        pub extern "ws2_32" fn inet_pton(af: c_int, src: [*:0]const u8, dst: *anyopaque) callconv(.winapi) c_int;
        pub extern "ws2_32" fn ioctlsocket(s: SOCKET, cmd: c_long, argp: *c_ulong) callconv(.winapi) c_int;
        pub extern "ws2_32" fn listen(s: SOCKET, backlog: c_int) callconv(.winapi) c_int;
        pub extern "ws2_32" fn setsockopt(s: SOCKET, level: c_int, optname: c_int, optval: [*]const u8, optlen: c_int) callconv(.winapi) c_int;
        pub extern "ws2_32" fn shutdown(s: SOCKET, how: c_int) callconv(.winapi) c_int;
        pub extern "ws2_32" fn socket(af: c_int, kind: c_int, protocol: c_int) callconv(.winapi) SOCKET;
        pub extern "ws2_32" fn WSACleanup() callconv(.winapi) c_int;
        pub extern "ws2_32" fn WSAConnect(s: SOCKET, name: ?*const struct_sockaddr, namelen: c_int, caller: ?*anyopaque, callee: ?*anyopaque, sqos: ?*anyopaque, gqos: ?*anyopaque) callconv(.winapi) c_int;
        pub extern "ws2_32" fn WSAGetLastError() callconv(.winapi) c_int;
        pub extern "ws2_32" fn WSAIoctl(s: SOCKET, code: DWORD, in_buf: ?*anyopaque, in_len: DWORD, out_buf: ?*anyopaque, out_len: DWORD, returned: *DWORD, overlapped: ?*anyopaque, routine: ?*anyopaque) callconv(.winapi) c_int;
        pub extern "ws2_32" fn WSASocketW(af: c_int, kind: c_int, protocol: c_int, info: ?*anyopaque, g: c_uint, flags: DWORD) callconv(.winapi) SOCKET;
        pub extern "ws2_32" fn WSAStartup(version: u16, data: *WSADATA) callconv(.winapi) c_int;
        pub extern "mswsock" fn AcceptEx(listen_s: SOCKET, accept_s: SOCKET, buf: ?*anyopaque, recv_len: DWORD, local_len: DWORD, remote_len: DWORD, received: ?*DWORD, overlapped: ?*anyopaque) callconv(.winapi) c_int;
        pub extern fn gai_strerrorA(code: c_int) callconv(.c) [*:0]const u8;
    };
};

// ==========================================================================
// Public functions
// ==========================================================================

/// `accept(2)`.
pub inline fn accept(sock: JSock, addr: ?*sys.struct_sockaddr, len: ?*SockLen) JSock {
    return if (windows) sys.win.accept(sock, addr, len) else std.c.accept(sock, addr, len);
}

/// `accept4(2)`, which is Linux's and FreeBSD's alone.
pub inline fn accept4(sock: JSock, addr: ?*sys.struct_sockaddr, len: ?*SockLen, flags: c_int) c_int {
    return std.c.accept4(sock, addr, len, @bitCast(flags));
}

/// `bind(2)`.
pub inline fn bind(sock: JSock, addr: ?*const sys.struct_sockaddr, len: SockLen) c_int {
    return if (windows) sys.win.bind(sock, addr, len) else std.c.bind(sock, addr, len);
}

/// `connect(2)`. `addr` is not null; the declaration takes a pointer that may
/// be.
pub inline fn connect(sock: JSock, addr: ?*const sys.struct_sockaddr, len: SockLen) c_int {
    return if (windows) sys.win.connect(sock, addr, len) else std.c.connect(sock, addr.?, len);
}

/// `gai_strerror`, which mingw defines as `__MINGW_NAME_AW(gai_strerror)`, a
/// macro over the ANSI and wide spellings.
pub inline fn gaiStrerror(status: c_int) [*:0]const u8 {
    return if (windows) sys.gai_strerrorA(status) else std.c.gai_strerror(@fromBackingInt(@intCast(status)));
}

/// `freeaddrinfo`, which does nothing for a null chain. A lookup that succeeds
/// and matches nothing leaves the chain null, and musl's `freeaddrinfo`
/// follows the pointer it is given.
pub inline fn freeAddrInfo(ai: ?*sys.struct_addrinfo) void {
    if (ai) |chain| sys.freeaddrinfo(chain);
}

/// `getaddrinfo`, returning the status as the `int` C declares.
pub inline fn getaddrinfo(
    node: ?[*:0]const u8,
    service: ?[*:0]const u8,
    hints: *const sys.struct_addrinfo,
    res: *?*sys.struct_addrinfo,
) c_int {
    if (windows) return sys.win.getaddrinfo(node, service, hints, res);
    return @backingInt(std.c.getaddrinfo(node, service, hints, res));
}

/// `getsockopt`.
pub inline fn getSockOpt(s: JSock, level: c_int, name: c_int, val: *anyopaque, len: *SockLen) c_int {
    if (windows) return sys.win.getsockopt(s, level, name, @ptrCast(val), len);
    return std.c.getsockopt(s, level, @bitCast(name), val, len);
}

/// `getpeername(2)`.
pub inline fn getpeername(sock: JSock, addr: *sys.struct_sockaddr, len: *SockLen) c_int {
    return if (windows) sys.win.getpeername(sock, addr, len) else std.c.getpeername(sock, addr, len);
}

/// `getsockname(2)`.
pub inline fn getsockname(sock: JSock, addr: *sys.struct_sockaddr, len: *SockLen) c_int {
    return if (windows) sys.win.getsockname(sock, addr, len) else std.c.getsockname(sock, addr, len);
}

/// `htonl`, for the reason `ntohs` gives.
pub inline fn htonl(x: u32) u32 {
    return std.mem.nativeToBig(u32, x);
}

/// `inet_ntop`.
pub inline fn inetNtop(af: c_int, src: *const anyopaque, dst: [*]u8, size: usize) ?[*:0]const u8 {
    return sys.inet_ntop(af, src, dst, @intCast(size));
}

/// `ntohs`. macOS spells it as a macro over `__DARWIN_OSSwapInt16`, so this is
/// written rather than borrowed on every platform for the sake of one.
pub inline fn ntohs(x: u16) u16 {
    return std.mem.bigToNative(u16, x);
}

/// `setsockopt`.
pub inline fn setSockOpt(s: JSock, level: c_int, name: c_int, val: *const anyopaque, len: usize) c_int {
    if (windows) return sys.win.setsockopt(s, level, name, @ptrCast(val), @intCast(len));
    return std.c.setsockopt(s, level, @bitCast(name), val, @intCast(len));
}

/// `JSOCKCLOSE`.
pub inline fn sockClose(s: JSock) void {
    if (windows) {
        _ = sys.closesocket(s);
    } else {
        _ = sys.close(s);
    }
}

/// Whether `s` names a socket rather than the default.
pub inline fn sockValid(s: JSock) bool {
    return if (windows) s != sys.INVALID_SOCKET else s >= 0;
}

// ==========================================================================
// Tests
// ==========================================================================

comptime {
    std.debug.assert(@sizeOf(sys.struct_ip_mreq) == 8);
    std.debug.assert(@sizeOf(sys.struct_ipv6_mreq) == 20);
    std.debug.assert(@offsetOf(sys.struct_ipv6_mreq, "ipv6mr_interface") == 16);
    if (has_ipv6) {
        // `port` after the family, `addr` after the flow label.
        std.debug.assert(@offsetOf(SockAddrIn6, "port") == 2);
        std.debug.assert(@offsetOf(SockAddrIn6, "addr") == 8);
    }
}
