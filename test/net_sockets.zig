//! Behavioral contract for the socket layer.
//!
//! ## What the Janet suites cannot reach
//!
//! `test/suite-net.janet` and the `net/` assertions in `test/suite-ev.janet`
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
//! contract that hangs when it is wrong. `test/suite-ev.janet` runs them inside
//! the loop, where they belong. What is checked here is everything before the
//! suspension: the argument decoding, the address lookup, the socket setup and
//! every raise on the way.
//!
//! ## Two things about how the subjects are reached
//!
//! A refusal is a value: this calls the cfunction and reads the error.
//!
//! The address structures come from `std.posix` rather than from the host
//! headers. Building a `sockaddr_in` from the same translation the subject
//! reads would make the two descriptions one. `std`'s are written per platform
//! and independently, so the bytes this file lays down and the bytes the
//! decoder reads come from two different descriptions and a disagreement is a
//! failure rather than a silence. It also keeps the contract module free of a
//! fourth `@cImport` of the socket headers.

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
const posix = std.posix;
const pp_describe = @import("subsystems").pp_describe;
const raise = @import("subsystems").raise;
const repr = @import("repr");
const strings = @import("subsystems").value.strings;
const subsystems = @import("subsystems");
const tuples = @import("subsystems").value.tuples;
const value = @import("subsystems").value;
const vm_lifecycle = @import("subsystems").lifecycle;
const wrap = @import("subsystems").value.wrap;

// ==========================================================================
// Constants
// ==========================================================================

/// Ten on Windows, which reaches neither the unix-domain bindhost refusal nor
/// anything else this file guards. The count is asserted at the end, because a
/// case that silently stopped raising would otherwise pass.
const expected_raises: u32 = if (windows) 10 else 11;
const has_ipv6 = config.ipv6;

/// Every name `net.libNet` registers, in the order it registers them. The
/// order is not itself pinned, a table having none, but the list is: a
/// binding that stops being registered is what this catches, and a
/// registration table is the one place a cfunction can go missing without a
/// link error.
const net_bindings = [_][*:0]const u8{
    "net/address",     "net/listen",    "net/socket",    "net/accept",
    "net/accept-loop", "net/read",      "net/chunk",     "net/write",
    "net/send-to",     "net/recv-from", "net/flush",     "net/connect",
    "net/shutdown",    "net/peername",  "net/localname", "net/address-unpack",
    "net/setsockopt",
};

var raises_seen: u32 = 0;
const windows = builtin.os.tag == .windows;

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

/// A cfunction expected to return, called by the name the registry has for it.
/// This is the pointer `net.libNet` registered, so it is the same cfunction a
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

fn asBytes(val: anytype) []const u8 {
    const bytes: [*]const u8 = @ptrCast(val);
    return bytes[0..@sizeOf(@TypeOf(val.*))];
}

fn unpack(address: repr.Value) repr.Value {
    var argv = [_]repr.Value{address};
    return callCore("net/address-unpack", &argv);
}

fn tupleIs2(val: repr.Value, host: []const u8, port: i32) bool {
    if (!harness.isType(val, repr.Tag.tuple)) return false;
    const t = wrap.toTuple(val);
    if (tuples.head(t).length != 2) return false;
    if (!harness.isType(t[0], repr.Tag.string)) return false;
    const text = wrap.toString(t[0]);
    const length: usize = strings.head(text).length;
    if (!std.mem.eql(u8, text[0..length], host)) return false;
    return args_core.checkint(t[1]) and wrap.toInteger(t[1]) == port;
}

fn tupleIs1(val: repr.Value, path: []const u8) bool {
    if (!harness.isType(val, repr.Tag.tuple)) return false;
    const t = wrap.toTuple(val);
    if (tuples.head(t).length != 1) return false;
    if (!harness.isType(t[0], repr.Tag.string)) return false;
    const text = wrap.toString(t[0]);
    const length: usize = strings.head(text).length;
    return std.mem.eql(u8, text[0..length], path);
}

fn pathLength(val: repr.Value) usize {
    expect(harness.isType(val, repr.Tag.tuple));
    const t = wrap.toTuple(val);
    expect(tuples.head(t).length == 1);
    return @intCast(strings.head(wrap.toString(t[0])).length);
}

/// An `AF_INET` address, laid out by `std.posix` and parsed by `std.Io.net`.
/// Zeroed first, because macOS's
/// `sin_len` is zero there too, and the decoder does not read it.
fn ip4(text: []const u8, port: u16) posix.sockaddr.in {
    const parsed = std.Io.net.Ip4Address.parse(text, port) catch unreachable;
    var sin = std.mem.zeroes(posix.sockaddr.in);
    sin.family = posix.AF.INET;
    sin.port = std.mem.nativeToBig(u16, port);
    sin.addr = @bitCast(parsed.bytes);
    return sin;
}

fn ip6(text: []const u8, port: u16) posix.sockaddr.in6 {
    const parsed = std.Io.net.Ip6Address.parse(text, port) catch unreachable;
    var sin6 = std.mem.zeroes(posix.sockaddr.in6);
    sin6.family = posix.AF.INET6;
    sin6.port = std.mem.nativeToBig(u16, port);
    sin6.addr = parsed.bytes;
    return sin6;
}

fn theRegistration() void {
    expect(net_bindings.len == 17);
    // `harness.core` asserts the binding resolves to a cfunction.
    for (net_bindings) |name| _ = harness.core(name);
}

fn theIpv4Decoding() void {
    {
        var sin = ip4("1.2.3.4", 8080);
        expect(tupleIs2(unpack(addressOf(asBytes(&sin))), "1.2.3.4", 8080));
    }

    // Port 0 and the wildcard address, which is what an unbound socket reports
    // and what `net/localname` returns before a bind.
    {
        var sin = ip4("0.0.0.0", 0);
        expect(tupleIs2(unpack(addressOf(asBytes(&sin))), "0.0.0.0", 0));
    }

    // The port is unsigned on the wire: 65535 must not come back negative.
    {
        var sin = ip4("255.255.255.255", 65535);
        expect(tupleIs2(unpack(addressOf(asBytes(&sin))), "255.255.255.255", 65535));
    }
}

fn theIpv6Decoding() void {
    {
        var sin6 = ip6("::1", 443);
        expect(tupleIs2(unpack(addressOf(asBytes(&sin6))), "::1", 443));
    }

    // The longest textual form there is, which is what sizes the decode
    // buffer: eight groups.
    {
        const text = "2001:db8:85a3:8d3:1319:8a2e:370:7348";
        var sin6 = ip6(text, 1);
        expect(tupleIs2(unpack(addressOf(asBytes(&sin6))), text, 1));
    }
}

fn theUnixDecoding() void {
    const path = "/tmp/janet-contract.sock";
    {
        var sun = std.mem.zeroes(posix.sockaddr.un);
        sun.family = posix.AF.UNIX;
        @memcpy(sun.path[0..path.len], path);
        expect(tupleIs1(unpack(addressOf(asBytes(&sun))), path));
    }

    // Linux's abstract namespace: the name starts at a NUL, and the decoder
    // shows that NUL as '@'. Only the *decoder* is free of the platform, so
    // this
    // address can be built and read back anywhere, which is the point of
    // building it by hand.
    {
        var sun = std.mem.zeroes(posix.sockaddr.un);
        sun.family = posix.AF.UNIX;
        const name = "abstract-name";
        sun.path[0] = 0;
        @memcpy(sun.path[1 .. 1 + name.len], name);
        expect(tupleIs1(unpack(addressOf(asBytes(&sun))), "@abstract-name"));
    }

    // A path that fills `sun_path` exactly, with no room for a terminator. The
    // decoder must stop at the end of the field rather than run past it.
    {
        var sun = std.mem.zeroes(posix.sockaddr.un);
        sun.family = posix.AF.UNIX;
        @memset(sun.path[0 .. sun.path.len - 1], 'x');
        expect(pathLength(unpack(addressOf(asBytes(&sun)))) == sun.path.len - 1);
    }
}

fn theUnknownFamily() void {
    // `AF_UNSPEC` is what a zeroed address reports, and nothing decodes it.
    var storage = std.mem.zeroes(posix.sockaddr.storage);
    storage.family = posix.AF.UNSPEC;
    var argv = [_]repr.Value{addressOf(asBytes(&storage))};
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

    // The port may also be a string, which is the branch `janet_checkint` does
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
/// of it; `tools/testing/leaks.sh` expects zero here, which is what says so.
fn theUnixAddressLookup() void {
    const path = "/tmp/janet-contract.sock";
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
        expect(pathLength(got) == @typeInfo(@FieldType(posix.sockaddr.un, "path")).array.len - 1);
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
        expect(harness.isType(name, repr.Tag.tuple));
        const t = wrap.toTuple(name);
        expect(tuples.head(t).length == 2);
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
        const methods: [*]const method_type.CMethod = @ptrCast(@alignCast(stream.methods));
        for (expected, 0..) |name, i| {
            expect(methods[i].name != null);
            expect(std.mem.eql(u8, std.mem.span(methods[i].name.?), name));
            expect(methods[i].cfun != null);
        }
        expect(methods[expected.len].name == null);
        expect(methods[expected.len].cfun == null);
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
    // name-reading cfunctions check it themselves rather than through
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
    // `net/socket` binds nothing, so its local name is the wildcard address on
    // port zero, which is the one decode a live socket cannot produce.
    {
        var argv = [_]repr.Value{ value.fromBytes("datagram", .keyword), value.fromBytes("ipv4", .keyword) };
        const sock = callCore("net/socket", &argv);
        expect(harness.isType(sock, repr.Tag.abstract));
        var name_argv = [_]repr.Value{sock};
        expect(tupleIs2(callCore("net/localname", &name_argv), "0.0.0.0", 0));
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
    std.debug.print("net_sockets contract ok ({d} raises)\n", .{raises_seen});
}
