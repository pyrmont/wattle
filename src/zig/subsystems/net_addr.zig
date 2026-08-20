//! Socket addresses: the `core/socket-address` abstract type, the two
//! vocabularies `net.c` reads out of Janet keywords, the `getaddrinfo` wrapper
//! every connecting and listening cfunction goes through, and the decoder that
//! turns a `struct sockaddr` back into a host/port pair. Part of the
//! `-Dnet-sockets` object; `net_sockets.zig` registers everything, including
//! the four cfunctions implemented here.
//!
//! The address abstract is a bare byte buffer -- `JANET_ATEND_NAME`, no
//! callbacks at all -- and that is what lets it cross to `ev_stream.zig`'s
//! `recvfrom` arm as an opaque pointer over either arm of `-Dev-loop`. Nothing
//! outside this file reads a field of one.
//!
//! ## Why this file is jump-transparent
//!
//! Every raise it makes itself is an ordinary `raise.Error` return. What it
//! cannot avoid is the argument layer: `janet_getcstring`, `janet_getabstract`
//! and their kin sit behind `-Dargs-core`, a selector's seam is the C ABI, and
//! their raise therefore arrives as a `longjmp` through these frames. So a
//! `getaddrinfo` result is released on every path explicitly, exactly as
//! `net.c` released it, and no `defer` may appear here until Part 17.

const std = @import("std");
const builtin = @import("builtin");
const abi = @import("abi");
const net_abi = @import("net_abi");
const raise = @import("raise");
const pp_format = @import("pp_format.zig");

const c = abi.c;
const stdio = @import("stdio.zig");
const lifecycle = @import("lifecycle.zig");
const containers = @import("containers.zig");
const arglayer = @import("arglayer.zig");
const abstract_type = @import("abstract_type.zig");
const h = net_abi.h;
const windows = net_abi.windows;
const has_ipv6 = net_abi.has_ipv6;
const SockLen = net_abi.SockLen;

/// `janet_address_type`. `JANET_ATEND_NAME` leaves every callback null, and
/// the translated structure defaults each field to null, so the name is the
/// whole definition.
pub export const janet_address_type: abstract_type.AbstractType = .{
    .name = "core/socket-address",
};

// ==========================================================================
// The two keyword vocabularies
// ==========================================================================

/// `net_get_address_family`. An unrecognised keyword is `AF_UNSPEC` rather
/// than an error, which is `net.c`'s behaviour whether or not it was its
/// intention.
pub fn addressFamily(x: c.Janet) c_int {
    if (c.janet_checktype(x, c.JANET_NIL) != 0) return h.AF_UNSPEC;
    if (c.janet_keyeq(x, "ipv4") != 0) return h.AF_INET;
    if (c.janet_keyeq(x, "ipv6") != 0) return h.AF_INET6;
    if (!windows) {
        if (c.janet_keyeq(x, "unix") != 0) return h.AF_UNIX;
    }
    return h.AF_UNSPEC;
}

/// `janet_get_sockettype`.
pub fn socketType(argv: [*c]c.Janet, argc: i32, n: i32) raise.Raising(c_int) {
    const stype = try arglayer.optKeyword(argv, argc, n, null);
    if (stype == null or c.janet_cstrcmp(stype, "stream") == 0) return h.SOCK_STREAM;
    if (c.janet_cstrcmp(stype, "datagram") != 0) {
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
    ai: [*c]h.struct_addrinfo = null,
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
            c.janet_free(p);
        } else {
            h.freeaddrinfo(self.ai);
        }
    }
};

/// `janet_get_addrinfo`. Needs `argc >= offset + 2`.
pub fn getAddrInfo(
    argv: [*c]c.Janet,
    offset: i32,
    socktype: c_int,
    passive: bool,
) raise.Raising(AddrInfo) {
    // Unix socket support - not yet supported on windows.
    if (!windows) {
        if (c.janet_keyeq(argv[@intCast(offset)], "unix") != 0) {
            const path = try arglayer.getCString(argv, offset + 1);
            const saddr: *net_abi.SockAddrUn = @ptrCast(@alignCast(
                c.janet_calloc(1, @sizeOf(net_abi.SockAddrUn)) orelse outOfMemory(@src()),
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
                        @as(usize, @intCast(c.janet_string_length(path))));
                }
            }
            return .{ .un = saddr, .size = size };
        }
    }

    // Get host and port.
    const host = try arglayer.getCString(argv, offset);
    const port = if (c.janet_checkint(argv[@intCast(offset + 1)]) != 0)
        c.janet_to_string(argv[@intCast(offset + 1)])
    else
        try arglayer.optCString(argv, offset + 2, offset + 1, null);

    var ai: [*c]h.struct_addrinfo = null;
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
pub fn soGetName(sa_any: ?*const anyopaque) raise.Raising(c.Janet) {
    const sa: *const h.struct_sockaddr = @ptrCast(@alignCast(sa_any));
    var buffer: [net_abi.sa_addrstrlen]u8 = undefined;
    const family: c_int = sa.sa_family;

    if (family == h.AF_INET) {
        const sai: *const h.struct_sockaddr_in = @ptrCast(@alignCast(sa_any));
        if (net_abi.inetNtop(h.AF_INET, &sai.sin_addr, &buffer, buffer.len) == null) {
            return raise.panic("unable to decode ipv4 host address");
        }
        var pair = [2]c.Janet{
            c.janet_cstringv(&buffer),
            wrapInteger(net_abi.ntohs(sai.sin_port)),
        };
        return c.janet_wrap_tuple(c.janet_tuple_n(&pair, 2));
    }

    if (has_ipv6) {
        if (family == h.AF_INET6) {
            const sai6: *const net_abi.SockAddrIn6 = @ptrCast(@alignCast(sa_any));
            if (net_abi.inetNtop(h.AF_INET6, &sai6.sin6_addr, &buffer, buffer.len) == null) {
                // "ipv4" is the C original's word, in its IPv6 arm. A port
                // reproduces defined behaviour; `FOUND.md` has the entry.
                return raise.panic("unable to decode ipv4 host address");
            }
            var pair = [2]c.Janet{
                c.janet_cstringv(&buffer),
                wrapInteger(net_abi.ntohs(sai6.sin6_port)),
            };
            return c.janet_wrap_tuple(c.janet_tuple_n(&pair, 2));
        }
    }

    if (!windows) {
        if (family == h.AF_UNIX) {
            const sun: *const net_abi.SockAddrUn = @ptrCast(@alignCast(sa_any));
            var pathname: c.Janet = undefined;
            if (sun.sun_path[0] == 0) {
                // An abstract address: the leading NUL shows as '@', and the
                // whole fixed-size path is copied because the name behind it
                // is not NUL-terminated.
                @memcpy(buffer[0..sun.sun_path.len], &sun.sun_path);
                buffer[0] = '@';
                pathname = c.janet_cstringv(&buffer);
            } else {
                pathname = c.janet_cstringv(&sun.sun_path);
            }
            return c.janet_wrap_tuple(c.janet_tuple_n(&pathname, 1));
        }
    }

    return raise.panic("unknown address family");
}

/// `janet_wrap_integer`, written out. `janet.h` declares the function beside
/// its macro and `wrap.c` defines it only for the two nanbox layouts, so a
/// tagged build has no such symbol. `ev_loop.zig` was the fifth subsystem to
/// meet this and `FOUND.md` records it.
inline fn wrapInteger(x: anytype) c.Janet {
    return c.janet_wrap_number(@floatFromInt(x));
}

// ==========================================================================
// The four address cfunctions
// ==========================================================================

extern const janet_stream_type: abstract_type.AbstractType;

const stream_closed: u32 = @intCast(c.JANET_STREAM_CLOSED);

/// Copy `len` bytes of a socket address into a fresh `core/socket-address`.
fn addressAbstract(from: ?*const anyopaque, len: usize) c.Janet {
    const abst = c.janet_abstract(abstract_type.stored(&janet_address_type), len);
    @memcpy(
        @as([*]u8, @ptrCast(abst))[0..len],
        @as([*]const u8, @ptrCast(from))[0..len],
    );
    return c.janet_wrap_abstract(abst);
}

/// `cfun_net_sockaddr`, registered as `net/address`.
pub fn sockaddrImpl(argc: i32, argv: [*c]c.Janet) raise.Raising(c.Janet) {
    try lifecycle.sandboxAssert(c.JANET_SANDBOX_NET_CONNECT); // connect OR listen
    try arglayer.arity(argc, 2, 4);
    const socktype = try socketType(argv, argc, 2);
    // The guard counts to three and the subscript counts to four, so a
    // three-argument call reads a slot it was not given. `FOUND.md` has the
    // entry; the read is inside the fiber's own stack, so it is a wrong answer
    // rather than a fault, and the condition is reproduced as written.
    const make_arr = argc >= 3 and c.janet_truthy(argv[3]) != 0;
    const info = try getAddrInfo(argv, 0, socktype, false);

    if (!windows) {
        // No unix domain socket support on windows yet. `net.c` returns from
        // here without releasing `info`, which `FOUND.md` records and this
        // reproduces.
        if (info.un) |saddr| {
            const ret = addressAbstract(saddr, @intCast(info.size));
            if (!make_arr) return ret;
            var one = [_]c.Janet{ret};
            return c.janet_wrap_array(c.janet_array_n(&one, 1));
        }
    }

    if (make_arr) {
        // Select all.
        const arr = c.janet_array(10);
        var iter = info.ai;
        while (iter != null) : (iter = iter.*.ai_next) {
            try containers.arrayPush(arr, addressAbstract(iter.*.ai_addr, @intCast(iter.*.ai_addrlen)));
        }
        info.free();
        return c.janet_wrap_array(arr);
    }

    // Select first.
    if (info.ai == null) return raise.panic("no data for given address");
    const ret = addressAbstract(info.ai.*.ai_addr, @intCast(info.ai.*.ai_addrlen));
    info.free();
    return ret;
}

/// `cfun_net_address_unpack`, registered as `net/address-unpack`.
pub fn addressUnpackImpl(argc: i32, argv: [*c]c.Janet) raise.Raising(c.Janet) {
    try arglayer.fixarity(argc, 1);
    return soGetName(try arglayer.getAbstract(argv, 0, abstract_type.stored(&janet_address_type)));
}

/// `cfun_net_getsockname`, registered as `net/localname`.
pub fn getsocknameImpl(argc: i32, argv: [*c]c.Janet) raise.Raising(c.Janet) {
    return endpointName(argc, argv, false);
}

/// `cfun_net_getpeername`, registered as `net/peername`.
pub fn getpeernameImpl(argc: i32, argv: [*c]c.Janet) raise.Raising(c.Janet) {
    return endpointName(argc, argv, true);
}

/// The two are the same cfunction but for the host call and one word of the
/// failure message. `net.c` writes them out twice; the duplication is not part
/// of the behaviour.
fn endpointName(argc: i32, argv: [*c]c.Janet, comptime peer: bool) raise.Raising(c.Janet) {
    try arglayer.fixarity(argc, 1);
    const js: *c.JanetStream = @ptrCast(@alignCast(try arglayer.getAbstract(argv, 0, abstract_type.stored(&janet_stream_type))));
    if (js.flags & stream_closed != 0) return raise.panic("stream closed");
    var ss = std.mem.zeroes(h.struct_sockaddr_storage);
    var slen: SockLen = @sizeOf(h.struct_sockaddr_storage);
    const call = if (peer) h.getpeername else h.getsockname;
    if (call(sockOf(js), @ptrCast(&ss), &slen) != 0) {
        const what = if (peer) "peername" else "localname";
        return pp_format.panicf(
            "Failed to get " ++ what ++ " on %v: %V",
            .{ argv[0], c.janet_ev_lasterr() },
        );
    }
    assert(@src(), slen <= @sizeOf(h.struct_sockaddr_storage), "socket address truncated");
    return soGetName(&ss);
}

/// `(JSock) stream->handle`. A `JanetHandle` is a `void *` on Windows, where a
/// `SOCKET` is an unsigned integer of the same width, and an `int` elsewhere.
pub inline fn sockOf(s: *const c.JanetStream) net_abi.JSock {
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

extern fn fwrite(ptr: [*]const u8, size: usize, n: usize, stream_handle: ?*c.FILE) callconv(.c) usize;
extern fn abort() callconv(.c) noreturn;
extern fn exit(status: c_int) callconv(.c) noreturn;
