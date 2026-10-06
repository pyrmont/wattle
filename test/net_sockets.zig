//! Behavioral contract for the socket layer.
//!
//! ## What the Janet suites cannot reach
//!
//! `test/suite-net.wattle` and the `net/` assertions in `test/suite-ev.wattle`
//! drive real sockets over the loopback interface, which is what they are for.
//! Five things have no Janet spelling at all:
//!
//!  - A socket address this machine cannot produce. `soGetName`, the decoder
//!    behind `net/address-unpack`, `net/localname` and `net/peername`,
//!    switches on `sa_family`, and a Janet program can only give it a family
//!    the host actually produced. A host with no IPv6 route never reaches the
//!    `AF_INET6` arm, no host reaches the "unknown address family" arm, and a
//!    macOS host cannot construct Linux's abstract unix address, whose leading
//!    NUL is what selects the `'@'` branch. All four are a `@memset` and an
//!    `abstracts.newBytes` away, because `net.addressType` is a bare byte
//!    buffer with no callbacks, which is also what lets the abstract be built
//!    by hand at all.
//!  - The order of the stream method table. `ev_stream.Stream` is public and
//!    its `methods` member is the table, so the fourteen rows can be read back
//!    in order. From Janet only membership is visible.
//!  - The failure paths that need an argument no Janet caller would write. A
//!    raise is asserted here by its *message* rather than by its existence,
//!    which is the difference between a test and a tautology.
//!  - A `sun_path` longer than the structure. The truncating copy is invisible
//!    from Janet, which sees only the shortened name coming back.
//!
//! ## What it deliberately does not do
//!
//! It does not open a connection. `net/connect` and `net/accept` end by
//! suspending the calling fiber on the event loop, so driving either from here
//! means running the loop, and a contract that waits on the kernel is a
//! contract that hangs when it is wrong. `test/suite-ev.wattle` runs them inside
//! the loop, where they belong. What is checked here is everything before the
//! suspension: the argument decoding, the address lookup, the socket setup and
//! every raise on the way.
//!
//! ## Two things about how the subjects are reached
//!
//! A refusal is a value: this calls the nfunction and reads the error.
//!
//! The socket addresses are laid down byte by byte from the table under
//! Constants, which is written from each platform's socket ABI. `net.zig`
//! reads `std`'s address structures, so building the bytes from `std` as well
//! would make the subject and the oracle one description. With two, a
//! disagreement is a failure rather than a silence.

// ==========================================================================
// Standard library imports
// ==========================================================================

const std = @import("std");
const builtin = @import("builtin");

// ==========================================================================
// Project imports
// ==========================================================================

const abi = @import("abi");
const abstracts = @import("subsystems").value.abstracts;
const args_core = @import("subsystems").args;
const config = @import("config");
const core_env = @import("subsystems").env;
const ev_stream = @import("subsystems").ev_stream;
const expect = @import("expect.zig").expect;
const gc_alloc = @import("subsystems").gc_alloc;
const harness = @import("harness.zig");
const method_type = @import("subsystems").method_type;
const net_addr = subsystems.net;
const pp_describe = @import("subsystems").pp_describe;
const raise = @import("subsystems").raise;
const repr = @import("repr");
const strings = @import("subsystems").value.strings;
const subsystems = @import("subsystems");
const value = @import("subsystems").value;
const vm_lifecycle = @import("subsystems").lifecycle;
const wrap = @import("subsystems").value.wrap;

// ==========================================================================
// Constants
// ==========================================================================

/// Eleven either way, and the two platforms do not get there by the same
/// route. Windows reaches neither the unix-domain bindhost refusal nor
/// anything else this file guards, and reaches the unbound-socket refusal,
/// which POSIX does not because it answers a name instead. The two cancel.
///
/// The count is asserted at the end, because a case that silently stopped
/// raising would otherwise pass.
const expected_raises: u32 = 11;
const has_ipv6 = config.ipv6;

/// Every name `net.libNet` registers, in the order it registers them. The
/// order is not itself pinned, a table having none, but the list is: a
/// binding that stops being registered is what this catches, and a
/// registration table is the one place an nfunction can go missing without a
/// link error.
const net_bindings = [_][*:0]const u8{
    "net/address",     "net/listen",    "net/socket",    "net/accept",
    "net/accept-loop", "net/read",      "net/chunk",     "net/write",
    "net/send-to",     "net/recv-from", "net/flush",     "net/connect",
    "net/shutdown",    "net/peername",  "net/localname", "net/address-unpack",
    "net/setsockopt",
};

var raises_seen: u32 = 0;
const windows = builtin.target.os.tag == .windows;

/// Whether the platform's socket addresses open with a length byte and a
/// one-byte family, as macOS and FreeBSD do, rather than a two-byte family.
const bsd_layout = builtin.target.os.tag.isDarwin() or builtin.target.os.tag == .freebsd;

/// The address families, as each platform numbers them. `AF_UNSPEC` is 0,
/// `AF_UNIX` 1 and `AF_INET` 2 everywhere, and `AF_INET6` is not.
const af_unix: u16 = 1;
const af_inet: u16 = 2;
const af_inet6: u16 = switch (builtin.target.os.tag) {
    .linux => 10,
    .windows => 23,
    .freebsd => 28,
    else => 30,
};

/// The length of `sun_path`: 108 bytes on Linux, and 104 on macOS and FreeBSD.
const sun_path_len: usize = if (bsd_layout) 104 else 108;

// ==========================================================================
// Cases
// ==========================================================================

fn expectRaise(name: [*:0]const u8, argv: []repr.Value, message: []const u8) void {
    const r = harness.coreRaised(name, argv) orelse {
        std.debug.print("net_sockets: expected a raise saying: {s}\n", .{message});
        @panic("net_sockets: expected a raise, got a return");
    };
    expect(r.signal == abi.Signal.@"error");
    if (!r.says(message)) {
        std.debug.print("expected: {s}\n", .{message});
        std.debug.print("     got: {s}\n", .{pp_describe.toString(r.payload)});
        @panic("net_sockets: the raise carried another message");
    }
    raises_seen += 1;
}

/// For a message whose tail is the host's own wording, `gai_strerror` and
/// `strerror` differ by platform and by libc, and pinning them would make this
/// contract a test of the C library, or which names a stream and therefore
/// renders an address.
fn expectRaisePrefix(name: [*:0]const u8, argv: []repr.Value, prefix: []const u8) void {
    const r = harness.coreRaised(name, argv) orelse {
        std.debug.print("net_sockets: expected a raise starting: {s}\n", .{prefix});
        @panic("net_sockets: expected a raise, got a return");
    };
    expect(r.signal == abi.Signal.@"error");
    if (!r.beginsWith(prefix)) {
        std.debug.print("expected prefix: {s}\n", .{prefix});
        std.debug.print("            got: {s}\n", .{pp_describe.toString(r.payload)});
        @panic("net_sockets: the raise carried another message");
    }
    raises_seen += 1;
}

/// An nfunction expected to return, called by the name the registry has for it.
/// This is the pointer `net.libNet` registered, so it is the same nfunction a
/// Janet call would reach.
fn callCore(name: [*:0]const u8, argv: []repr.Value) repr.Value {
    return harness.callCore(name, argv) catch
        @panic("net_sockets: a call that should have returned raised");
}

/// Wrap `bytes` as a `core/socket-address`, which is what `net/address-unpack`
/// takes. The abstract has no callbacks, so this is the whole of building one.
fn addressOf(bytes: []const u8) repr.Value {
    const abst = abstracts.newBytes(
        &net_addr.addressType,
        bytes.len,
    );
    const destination: [*]u8 = @ptrCast(abst);
    @memcpy(destination[0..bytes.len], bytes);
    return wrap.fromAbstract(abst);
}

fn unpack(address: repr.Value) repr.Value {
    var argv = [_]repr.Value{address};
    return callCore("net/address-unpack", &argv);
}

fn tupleIs2(val: repr.Value, host: []const u8, port: i32) bool {
    if (!harness.isIndexed(val)) return false;
    const t = harness.elems(val);
    if (t.len != 2) return false;
    if (!harness.isType(t[0], repr.Tag.string)) return false;
    const text = wrap.toString(t[0]);
    const length: usize = strings.head(text).length;
    if (!std.mem.eql(u8, text[0..length], host)) return false;
    return args_core.checkint(t[1]) and wrap.toInteger(t[1]) == port;
}

fn tupleIs1(val: repr.Value, path: []const u8) bool {
    if (!harness.isIndexed(val)) return false;
    const t = harness.elems(val);
    if (t.len != 1) return false;
    if (!harness.isType(t[0], repr.Tag.string)) return false;
    const text = wrap.toString(t[0]);
    const length: usize = strings.head(text).length;
    return std.mem.eql(u8, text[0..length], path);
}

fn pathLength(val: repr.Value) usize {
    expect(harness.isIndexed(val));
    const t = harness.elems(val);
    expect(t.len == 1);
    return @intCast(strings.head(wrap.toString(t[0])).length);
}

/// Writes the family at the head of a socket address. The length byte that
/// macOS and FreeBSD put first stays zero, and the decoder does not read it.
fn putFamily(bytes: []u8, family: u16) void {
    if (bsd_layout) {
        bytes[1] = @intCast(family);
    } else {
        std.mem.writeInt(u16, bytes[0..2], family, builtin.target.cpu.arch.endian());
    }
}

/// An `AF_INET` address: the family, the port in network order at offset 2,
/// and the four address bytes at offset 4, in 16 bytes. The text is parsed by
/// `std.Io.net`.
fn ip4(text: []const u8, port: u16) [16]u8 {
    const parsed = std.Io.net.Ip4Address.parse(text, port) catch unreachable;
    var bytes = std.mem.zeroes([16]u8);
    putFamily(&bytes, af_inet);
    std.mem.writeInt(u16, bytes[2..4], port, .big);
    @memcpy(bytes[4..8], &parsed.bytes);
    return bytes;
}

/// An `AF_INET6` address: the family, the port in network order at offset 2,
/// the flow label at 4, and the sixteen address bytes at 8, in 28 bytes.
fn ip6(text: []const u8, port: u16) [28]u8 {
    const parsed = std.Io.net.Ip6Address.parse(text, port) catch unreachable;
    var bytes = std.mem.zeroes([28]u8);
    putFamily(&bytes, af_inet6);
    std.mem.writeInt(u16, bytes[2..4], port, .big);
    @memcpy(bytes[8..24], &parsed.bytes);
    return bytes;
}

/// An `AF_UNIX` address with an empty path: the family, then `sun_path` at
/// offset 2.
fn unixAddress() [2 + sun_path_len]u8 {
    var bytes = std.mem.zeroes([2 + sun_path_len]u8);
    putFamily(&bytes, af_unix);
    return bytes;
}

fn theRegistration() void {
    expect(net_bindings.len == 17);
    // `harness.core` asserts the binding resolves to an nfunction.
    for (net_bindings) |name| _ = harness.core(name);
}

fn theIpv4Decoding() void {
    {
        var sin = ip4("1.2.3.4", 8080);
        expect(tupleIs2(unpack(addressOf(&sin)), "1.2.3.4", 8080));
    }

    // Port 0 and the wildcard address, which is what an unbound socket reports
    // and what `net/localname` returns before a bind.
    {
        var sin = ip4("0.0.0.0", 0);
        expect(tupleIs2(unpack(addressOf(&sin)), "0.0.0.0", 0));
    }

    // The port is unsigned on the wire: 65535 must not come back negative.
    {
        var sin = ip4("255.255.255.255", 65535);
        expect(tupleIs2(unpack(addressOf(&sin)), "255.255.255.255", 65535));
    }
}

fn theIpv6Decoding() void {
    {
        var sin6 = ip6("::1", 443);
        expect(tupleIs2(unpack(addressOf(&sin6)), "::1", 443));
    }

    // The longest textual form there is, which is what sizes the decode
    // buffer: eight groups.
    {
        const text = "2001:db8:85a3:8d3:1319:8a2e:370:7348";
        var sin6 = ip6(text, 1);
        expect(tupleIs2(unpack(addressOf(&sin6)), text, 1));
    }
}

fn theUnixDecoding() void {
    const path = "/tmp/wattle-contract.sock";
    {
        var sun = unixAddress();
        @memcpy(sun[2 .. 2 + path.len], path);
        expect(tupleIs1(unpack(addressOf(&sun)), path));
    }

    // Linux's abstract namespace: the name starts at a NUL, and the decoder
    // shows that NUL as '@'. Only the *decoder* is free of the platform, so
    // this
    // address can be built and read back anywhere, which is the point of
    // building it by hand.
    {
        var sun = unixAddress();
        const name = "abstract-name";
        @memcpy(sun[3 .. 3 + name.len], name);
        expect(tupleIs1(unpack(addressOf(&sun)), "@abstract-name"));
    }

    // A path that fills `sun_path` exactly, with no room for a terminator. The
    // decoder must stop at the end of the field rather than run past it.
    {
        var sun = unixAddress();
        @memset(sun[2 .. 2 + sun_path_len - 1], 'x');
        expect(pathLength(unpack(addressOf(&sun))) == sun_path_len - 1);
    }
}

fn theUnknownFamily() void {
    // `AF_UNSPEC` is what a zeroed address reports, and nothing decodes it.
    const storage = std.mem.zeroes([128]u8);
    var argv = [_]repr.Value{addressOf(&storage)};
    expectRaise("net/address-unpack", &argv, "unknown address family");
}

fn theAddressLookup() void {
    // A numeric host needs no resolver, so this is the one lookup that is the
    // same on every machine and in every network.
    var argv = [_]repr.Value{
        value.fromBytes("127.0.0.1", .string),
        harness.wrapInteger(9999),
        wrap.fromNil(),
        wrap.fromNil(),
    };
    expect(tupleIs2(unpack(callCore("net/address", argv[0..2])), "127.0.0.1", 9999));

    // The port may also be a string, which is the branch `checkint` does
    // not take.
    argv[1] = value.fromBytes("9999", .string);
    expect(tupleIs2(unpack(callCore("net/address", argv[0..2])), "127.0.0.1", 9999));

    // `multi` truthy returns an array of them, and every element decodes.
    argv[1] = harness.wrapInteger(9999);
    argv[2] = value.fromBytes("stream", .keyword);
    argv[3] = wrap.fromTrue();
    {
        const all = callCore("net/address", argv[0..4]);
        expect(harness.isType(all, repr.Tag.array));
        const array = wrap.toArray(all);
        expect(array.count >= 1);
        for (0..@intCast(array.count)) |i| {
            expect(tupleIs2(unpack(array.slice()[i]), "127.0.0.1", 9999));
        }
    }

    // `:datagram` is the other socket type, and it resolves the same host.
    argv[2] = value.fromBytes("datagram", .keyword);
    argv[3] = wrap.fromFalse();
    expect(tupleIs2(unpack(callCore("net/address", argv[0..4])), "127.0.0.1", 9999));
}

/// Three calls and no leaks. `net/address`'s unix-domain branch returns
/// through a `defer`, so the address it builds is released on every path out
/// of it; `res/testing/leaks.sh` expects zero here, which is what says so.
fn theUnixAddressLookup() void {
    const path = "/tmp/wattle-contract.sock";
    var argv = [_]repr.Value{
        value.fromBytes("unix", .keyword),
        value.fromBytes(path, .string),
        wrap.fromNil(),
        wrap.fromNil(),
    };
    expect(tupleIs1(unpack(callCore("net/address", argv[0..2])), path));

    // A name longer than `sun_path` is truncated rather than rejected, and the
    // terminator is kept, so what comes back is one byte short of the field.
    // A `snprintf` with the field's own size would behave the same way, and
    // nothing in Janet can see the difference between that and a copy that
    // overruns.
    {
        var big = std.mem.zeroes([512]u8);
        @memset(big[0 .. big.len - 1], 'a');
        argv[1] = value.fromBytes(std.mem.sliceTo(&big, 0), .string);
        const got = unpack(callCore("net/address", argv[0..2]));
        expect(pathLength(got) == sun_path_len - 1);
    }

    // `multi` on a unix path is the one-element array branch.
    {
        argv[1] = value.fromBytes(path, .string);
        argv[2] = value.fromBytes("stream", .keyword);
        argv[3] = wrap.fromTrue();
        const all = callCore("net/address", argv[0..4]);
        expect(harness.isType(all, repr.Tag.array));
        const array = wrap.toArray(all);
        expect(array.count == 1);
        expect(tupleIs1(unpack(array.slice()[0]), path));
    }
}

fn theArgumentFaults() void {
    // The socket type vocabulary: two keywords and nothing else.
    {
        var argv = [_]repr.Value{
            value.fromBytes("127.0.0.1", .string),
            harness.wrapInteger(9999),
            value.fromBytes("tcp", .keyword),
        };
        expectRaise(
            "net/address",
            &argv,
            "expected socket type as :stream or :datagram, got :tcp",
        );
    }

    // A host the resolver cannot resolve. The tail is `gai_strerror`'s and
    // differs by libc, so only the prefix is pinned.
    {
        var argv = [_]repr.Value{
            value.fromBytes("no-such-host.invalid", .string),
            harness.wrapInteger(9999),
        };
        expectRaisePrefix("net/address", &argv, "could not get address info: ");
    }

    if (windows) return;

    // A unix domain address cannot also be bound to an outgoing interface, and
    // `net/connect` is where that is decided.
    //
    // The path is short on purpose. Releasing this address with
    // `freeaddrinfo`, which did not allocate it, the unix arm of the lookup
    // returning an allocated `sockaddr_un` instead, reads `ai_canonname`
    // and `ai_next` out of `sun_path` and frees whatever it finds; measured on
    // this machine the path length at which that becomes an abort is between
    // 11 and 26 characters. `AddrInfo.free` picks the allocator from the
    // discriminant, so the length no longer decides anything, and eleven
    // characters is kept because the *message* is what this asserts.
    var argv = [_]repr.Value{
        value.fromBytes("unix", .keyword),
        value.fromBytes("/tmp/a.sock", .string),
        value.fromBytes("stream", .keyword),
        value.fromBytes("127.0.0.1", .string),
        harness.wrapInteger(0),
    };
    expectRaise("net/connect", &argv, "bindhost not supported for unix domain sockets");
}

fn theStreamFaults() void {
    // A listener is the one socket a contract can make without entering the
    // loop: `net/listen` returns before anything suspends.
    var listen_argv = [_]repr.Value{ value.fromBytes("127.0.0.1", .string), harness.wrapInteger(0) };
    const listener = callCore("net/listen", &listen_argv);
    expect(harness.isType(listener, repr.Tag.abstract));
    gc_alloc.gcroot(listener);
    defer _ = gc_alloc.gcunroot(listener);

    // Its local name is a real address, decoded by the same path the
    // hand-built ones above went through, and the number the kernel picked is
    // whatever it picked, so only the host is pinned.
    {
        var argv = [_]repr.Value{listener};
        const name = callCore("net/localname", &argv);
        expect(harness.isIndexed(name));
        const t = harness.elems(name);
        expect(t.len == 2);
        expect(harness.stringIs(wrap.toString(t[0]), "127.0.0.1"));
        expect(args_core.checkint(t[1]) and wrap.toInteger(t[1]) > 0);
    }

    // A listener has no peer, and the message names the stream it failed on.
    {
        var argv = [_]repr.Value{listener};
        expectRaisePrefix("net/peername", &argv, "Failed to get peername on ");
    }

    // The method table, in order. `ev_stream.Stream` is public, so the rows
    // can be read back; from Janet only membership is visible.
    {
        const expected = [_][]const u8{
            "chunk",   "close",       "read",     "write",      "flush",
            "accept",  "accept-loop", "send-to",  "recv-from",  "evread",
            "evchunk", "evwrite",     "shutdown", "setsockopt",
        };
        const stream: *ev_stream.Stream = @ptrCast(@alignCast(wrap.toAbstract(listener)));
        const methods: [*]const method_type.Method = @ptrCast(@alignCast(stream.methods));
        for (expected, 0..) |name, i| {
            expect(methods[i].name != null);
            expect(std.mem.eql(u8, std.mem.span(methods[i].name.?), name));
            expect(methods[i].nfun != null);
        }
        expect(methods[expected.len].name == null);
        expect(methods[expected.len].nfun == null);
    }

    // `net/shutdown`'s vocabulary is three keywords.
    {
        var argv = [_]repr.Value{ listener, value.fromBytes("both", .keyword) };
        expectRaise("net/shutdown", &argv, "unexpected keyword :both");
    }

    // And the option table's, which is a name it does not have.
    {
        var argv = [_]repr.Value{
            listener,
            value.fromBytes("so-nonsense", .keyword),
            wrap.fromTrue(),
        };
        expectRaise("net/setsockopt", &argv, "unknown socket option :so-nonsense");
    }

    // A handler that cannot be given the connection it is handed.
    {
        var handler = wrap.fromNil();
        expect(core_env.dostring(harness.coreEnv(), "(fn [] nil)", "contract", &handler) == 0);
        var argv = [_]repr.Value{ listener, handler };
        expectRaise("net/accept-loop", &argv, "handler function must take at least 1 argument");
    }

    // A closed stream is refused before any host call is made, and the two
    // name-reading nfunctions check it themselves rather than through
    // `ev/stream.streamFlags`.
    {
        const stream: *ev_stream.Stream = @ptrCast(@alignCast(wrap.toAbstract(listener)));
        raise.toAbi(ev_stream.streamClose(stream));
        var one = [_]repr.Value{listener};
        expectRaise("net/localname", &one, "stream closed");
        expectRaise("net/peername", &one, "stream closed");
        // Everything else reports through `streamFlags`, whose wording
        // belongs to the event loop rather than to this subsystem.
        var shutdown_argv = [_]repr.Value{ listener, value.fromBytes("rw", .keyword) };
        expectRaise("net/shutdown", &shutdown_argv, "stream is closed");
    }
}

fn theUnboundSocket() void {
    // `net/socket` binds nothing. POSIX still answers a local name, the
    // wildcard address on port zero, which is the one decode a live socket
    // cannot otherwise produce. Windows refuses instead: `getsockname` there
    // wants a socket that has been bound and answers `WSAEINVAL` without one,
    // so the claim on that host is the refusal.
    {
        var argv = [_]repr.Value{ value.fromBytes("datagram", .keyword), value.fromBytes("ipv4", .keyword) };
        const sock = callCore("net/socket", &argv);
        expect(harness.isType(sock, repr.Tag.abstract));
        var name_argv = [_]repr.Value{sock};
        if (windows) {
            // By prefix: the tail names the stream and then carries the
            // host's own wording, and neither is this runtime's to pin.
            expectRaisePrefix("net/localname", &name_argv, "Failed to get localname on ");
        } else {
            expect(tupleIs2(callCore("net/localname", &name_argv), "0.0.0.0", 0));
        }
        raise.toAbi(ev_stream.streamClose(@ptrCast(@alignCast(wrap.toAbstract(sock)))));
    }

    // No arguments at all is a stream socket in whatever family the resolver
    // prefers, which is the default path through the family lookup.
    {
        var none = [_]repr.Value{};
        const sock = callCore("net/socket", &none);
        expect(harness.isType(sock, repr.Tag.abstract));
        raise.toAbi(ev_stream.streamClose(@ptrCast(@alignCast(wrap.toAbstract(sock)))));
    }
}

// ==========================================================================
// Entry
// ==========================================================================

pub fn run() void {
    harness.init();
    defer vm_lifecycle.deinit();
    _ = harness.coreEnv();

    theRegistration();
    theIpv4Decoding();
    if (has_ipv6) theIpv6Decoding();
    if (!windows) theUnixDecoding();
    theUnknownFamily();
    theAddressLookup();
    if (!windows) theUnixAddressLookup();
    theArgumentFaults();
    theStreamFaults();
    theUnboundSocket();

    expect(raises_seen == expected_raises);
    std.debug.print("net_sockets raises: {d}\n", .{raises_seen});
}
