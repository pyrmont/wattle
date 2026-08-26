//! The single translation of the host socket headers `net.c` worked through.
//!
//! `net/abi.h` carries the reasoning, including why this is a third
//! translation rather than ten lines added to `abi.zig`, and why the Windows
//! arm is translated where `ev_stream.zig` declared its Winsock calls by hand.
//! The two files of the `-Dnet-sockets` object share this module, so a
//! `struct addrinfo` filled by one is the same Zig type as a `struct addrinfo`
//! read by the other.
//!
//! What is here beyond the translation is the handful of spellings `net.c`
//! made with the preprocessor and that a translation therefore cannot carry: a
//! socket handle's type and its invalid value, and one GUID that is a brace
//! initializer.

const std = @import("std");
const builtin = @import("builtin");
const config = @import("config");

pub const h = @cImport({
    @cInclude("net/abi.h");
});

pub const windows = builtin.os.tag == .windows;

/// `MSG_NOSIGNAL`, or the 0 `net.c` supplies where the platform has none.
pub const msg_nosignal: c_int = h.JANET_ZIG_MSG_NOSIGNAL;

/// Whether `serverify_socket` may ask for `SO_REUSEPORT`; see `net/abi.h`.
pub const has_reuseport = h.JANET_ZIG_REUSEPORT != 0;

/// Whether an `IP_MULTICAST_TTL` value is an `unsigned char`; see `net/abi.h`.
pub const multicast_ttl_char = h.JANET_ZIG_MULTICAST_TTL_CHAR != 0;

/// Whether this build has IPv6.
///
/// The build's own answer since Phase 12 increment 5f. It was
/// `h.JANET_ZIG_HAS_IPV6`, which `net/abi.h` restated from `janet.h`'s
/// `JANET_NO_IPV6` because translate-c does not surface a macro defined with
/// no value. `-Dipv6` is where the decision was all along, and with the header
/// gone there is no reason for it to travel through a C preprocessor to get
/// here.
pub const has_ipv6 = config.ipv6;

// ==========================================================================
// `JSock` and its four macros
// ==========================================================================

/// `JSock`: `SOCKET` on Windows and a file descriptor elsewhere.
pub const JSock = if (windows) h.SOCKET else c_int;

/// `JSOCKDEFAULT`. Note that the POSIX value is 0 rather than -1, which is a
/// valid descriptor; nothing reads it before assigning, and reproducing
/// `net.c` exactly is the rule.
pub const sock_default: JSock = if (windows) h.INVALID_SOCKET else 0;

/// `JSOCKVALID`.
pub inline fn sockValid(s: JSock) bool {
    return if (windows) s != h.INVALID_SOCKET else s >= 0;
}

/// `JSOCKFLAGS`: the extra `socket(2)` flags, which is `SOCK_CLOEXEC` where
/// the platform has it. macOS does not, and neither does Windows.
pub const sock_flags: c_int = if (windows or !@hasDecl(h, "SOCK_CLOEXEC")) 0 else h.SOCK_CLOEXEC;

/// `JSOCKCLOSE`.
pub inline fn sockClose(s: JSock) void {
    if (windows) {
        _ = h.closesocket(s);
    } else {
        _ = h.close(s);
    }
}

// ==========================================================================
// The socket-address calls, which glibc does not declare with a pointer
// ==========================================================================

/// Whether this target's `sockaddr` parameters arrive as a transparent union.
///
/// Under `_GNU_SOURCE` -- which `janet_features.h` sets -- glibc declares
/// `bind`, `getsockname`, `getpeername` and `accept4` with `__SOCKADDR_ARG`
/// and `__CONST_SOCKADDR_ARG`: unions of every `sockaddr_*` pointer, marked
/// `__attribute__((__transparent_union__))`. The C ABI passes such a union
/// exactly as the pointer inside it, which is the whole point of the
/// attribute, but `translate-c` has no rendering for it and produces a real
/// Zig union. Every call site then fails with `expected pointer type, found
/// 'cimport.__SOCKADDR_ARG'`.
///
/// musl, the BSDs and macOS declare the plain pointer, so this is glibc-only
/// in cause. Found in Phase 11 Part 25, when the first native glibc build this
/// project has ever attempted got as far as these five call sites.
const transparent_sockaddr = builtin.os.tag == .linux and builtin.abi.isGnu();

/// The four calls, taken by symbol where the declaration is unusable.
///
/// `@extern` names the symbol directly, so what is bypassed is glibc's
/// *prototype* and not its implementation -- the signatures below are the ABI
/// on every POSIX target, which is why the union is transparent in the first
/// place. Nothing here reaches Windows: `bind` and the rest live in `ws2_32`
/// with their own calling convention there, and `h` declares them correctly.
const CSockaddr = h.struct_sockaddr;
const bindPlain = @extern(*const fn (JSock, ?*const CSockaddr, h.socklen_t) callconv(.c) c_int, .{ .name = "bind" });
const getsocknamePlain = @extern(*const fn (JSock, ?*CSockaddr, *h.socklen_t) callconv(.c) c_int, .{ .name = "getsockname" });
const getpeernamePlain = @extern(*const fn (JSock, ?*CSockaddr, *h.socklen_t) callconv(.c) c_int, .{ .name = "getpeername" });

/// `bind(2)`. Use this rather than `h.bind`; see `transparent_sockaddr`.
pub inline fn bind(sock: JSock, addr: ?*const CSockaddr, len: h.socklen_t) c_int {
    if (transparent_sockaddr) return bindPlain(sock, addr, len);
    return h.bind(sock, addr, len);
}

/// `getsockname(2)`. Use this rather than `h.getsockname`.
pub inline fn getsockname(sock: JSock, addr: ?*CSockaddr, len: *h.socklen_t) c_int {
    if (transparent_sockaddr) return getsocknamePlain(sock, addr, len);
    return h.getsockname(sock, addr, len);
}

/// `getpeername(2)`. Use this rather than `h.getpeername`.
pub inline fn getpeername(sock: JSock, addr: ?*CSockaddr, len: *h.socklen_t) c_int {
    if (transparent_sockaddr) return getpeernamePlain(sock, addr, len);
    return h.getpeername(sock, addr, len);
}

/// `connect(2)`. Use this rather than `h.connect`.
const connectPlain = @extern(*const fn (JSock, ?*const CSockaddr, h.socklen_t) callconv(.c) c_int, .{ .name = "connect" });

pub inline fn connect(sock: JSock, addr: ?*const CSockaddr, len: h.socklen_t) c_int {
    if (transparent_sockaddr) return connectPlain(sock, addr, len);
    return h.connect(sock, addr, len);
}

/// `accept(2)`. Use this rather than `h.accept`.
const acceptPlain = @extern(*const fn (JSock, ?*CSockaddr, ?*h.socklen_t) callconv(.c) JSock, .{ .name = "accept" });

pub inline fn accept(sock: JSock, addr: ?*CSockaddr, len: ?*h.socklen_t) JSock {
    if (transparent_sockaddr) return acceptPlain(sock, addr, len);
    return h.accept(sock, addr, len);
}

/// `accept4(2)`, which is Linux's alone -- the BSDs inherit `SOCK_CLOEXEC`
/// from the listening socket and have no such call, so nothing outside Linux
/// reaches this and `accept4Plain` is never analysed there.
const accept4Plain = @extern(*const fn (JSock, ?*CSockaddr, ?*h.socklen_t, c_int) callconv(.c) c_int, .{ .name = "accept4" });

pub inline fn accept4(sock: JSock, addr: ?*CSockaddr, len: ?*h.socklen_t, flags: c_int) c_int {
    if (transparent_sockaddr) return accept4Plain(sock, addr, len, flags);
    return h.accept4(sock, addr, len, flags);
}

/// `SA_ADDRSTRLEN`: the buffer `janet_so_getname` decodes into. `net.c` takes
/// the larger of the numeric-address length and the unix path length, and has
/// no unix domain sockets on Windows.
pub const sa_addrstrlen: usize = blk: {
    const numeric: usize = if (has_ipv6) h.INET6_ADDRSTRLEN + 1 else h.INET_ADDRSTRLEN + 1;
    if (windows) break :blk numeric;
    const path: usize = @sizeOf(@FieldType(SockAddrUn, "sun_path")) + 1;
    break :blk @max(numeric, path);
};

// ==========================================================================
// Two structures the Windows translation cannot give us
// ==========================================================================

/// `struct sockaddr_un`, and an opaque stand-in where there is no such thing.
/// Windows has no unix domain sockets, `net.c` guards every use of one with
/// `#ifndef JANET_WINDOWS`, and a Zig *field type* is analysed whether or not
/// the code around it is -- so the stand-in is what lets `AddrInfo` name the
/// pointer on every target.
pub const SockAddrUn = if (windows) opaque {} else h.struct_sockaddr_un;

/// `struct sockaddr_in6`.
///
/// Windows' declaration ends in an anonymous union -- `sin6_scope_id` against
/// a `SCOPE_ID` -- and translate-c demotes any record holding one to
/// `opaque{}`, so on that target the modern structure has no fields at all.
/// `sockaddr_in6_old` is the same structure without that trailing union, so
/// its four members sit at the same offsets as the first four of the modern
/// one, and the two this project reads are both inside them. The two asserts
/// below are what makes that a checked claim rather than a hopeful one.
///
/// This is the same class of fault Part 13 met when `std.os.windows` stopped
/// declaring `OVERLAPPED`, arriving from the other side: there the
/// declaration was gone, here it survives translation with its fields
/// dissolved.
pub const SockAddrIn6 = if (windows) h.struct_sockaddr_in6_old else h.struct_sockaddr_in6;

comptime {
    if (has_ipv6) {
        std.debug.assert(@sizeOf(h.struct_in6_addr) == 16);
        // `sin6_port` after the family, `sin6_addr` after the flow label.
        std.debug.assert(@offsetOf(SockAddrIn6, "sin6_port") == 2);
        std.debug.assert(@offsetOf(SockAddrIn6, "sin6_addr") == 8);
    }
}

// ==========================================================================
// Windows
// ==========================================================================

/// `FIONBIO`, which `winsock2.h` builds with `_IOW` -- a macro whose body
/// translate-c cannot parse, because it contains a `sizeof`. The pieces it is
/// built from *do* survive, so this is the same expression rather than the
/// number it evaluates to (0x8004667E).
pub const fionbio: c_long = if (windows)
    @bitCast(@as(u32, @intCast(h.IOC_IN |
        ((@as(c_int, @sizeOf(h.u_long)) & h.IOCPARM_MASK) << 16) |
        (@as(c_int, 'f') << 8) |
        126)))
else
    0;

/// `WSAID_CONNECTEX`, the one declaration in `mswsock.h` that does not survive
/// translation: it is a brace initializer, and translate-c renders those as
/// `@compileError`. Naming it is what makes this restatement necessary rather
/// than the whole header.
pub const wsaid_connectex = if (windows) h.GUID{
    .Data1 = 0x25a207b9,
    .Data2 = 0xddf3,
    .Data3 = 0x4660,
    .Data4 = .{ 0x8e, 0xe9, 0x76, 0xe5, 0x8c, 0x74, 0x06, 0x3e },
} else undefined;

// ==========================================================================
// The spellings that differ between the two header sets
// ==========================================================================
//
// Winsock and the POSIX headers agree on what these calls do and disagree on
// how they are spelled: `setsockopt` takes a `char *` on one and a `void *`
// on the other, `inet_ntop` sizes its buffer with a `size_t` rather than a
// `socklen_t`, `gai_strerror` is a macro over an ANSI/wide pair, and
// `struct in_addr` hides its four bytes behind a union whose accessor is a
// macro. Normalising them here is what keeps `net_addr.zig` and
// `net_sockets.zig` free of `if (windows)` at every host call -- and each of
// these is the same *call*, so this is not the kind of platform arm the
// backends in `ev_backend.zig` are.

/// `socklen_t`: `c_uint` on Linux, `__darwin_socklen_t` on macOS and `c_int`
/// on Windows.
pub const SockLen = h.socklen_t;

/// `ntohs`. macOS spells it as a macro over `__DARWIN_OSSwapInt16`, which
/// translate-c does not surface at all, so this is written rather than
/// borrowed on every platform for the sake of one.
pub inline fn ntohs(x: u16) u16 {
    return std.mem.bigToNative(u16, x);
}

/// `htonl`, for the same reason.
pub inline fn htonl(x: u32) u32 {
    return std.mem.nativeToBig(u32, x);
}

/// `gai_strerror`, which mingw defines as `__MINGW_NAME_AW(gai_strerror)` --
/// a macro over the ANSI and wide spellings, which translate-c cannot render.
pub inline fn gaiStrerror(status: c_int) [*]const u8 {
    return if (windows) h.gai_strerrorA(status) else h.gai_strerror(status);
}

/// `setsockopt`.
pub inline fn setSockOpt(s: JSock, level: c_int, name: c_int, val: *const anyopaque, len: usize) c_int {
    return h.setsockopt(s, level, name, @ptrCast(val), @intCast(len));
}

/// `getsockopt`.
pub inline fn getSockOpt(s: JSock, level: c_int, name: c_int, val: *anyopaque, len: *SockLen) c_int {
    return h.getsockopt(s, level, name, @ptrCast(val), len);
}

/// `inet_ntop`.
pub inline fn inetNtop(af: c_int, src: *const anyopaque, dst: [*]u8, size: usize) ?[*:0]const u8 {
    return h.inet_ntop(af, @ptrCast(src), dst, @intCast(size));
}

/// The four bytes of a `struct in_addr`. POSIX names them `s_addr`; Winsock
/// puts them in an unnamed union and reaches them with a macro, which does not
/// survive translation. The structure is four bytes wide on both, and both
/// hold them in network order.
pub inline fn inAddrBits(a: *h.struct_in_addr) *u32 {
    comptime std.debug.assert(@sizeOf(h.struct_in_addr) == 4);
    return @ptrCast(@alignCast(a));
}
