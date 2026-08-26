//! Behavioral contract for the socket layer.
//!
//! ## What the Janet suites cannot reach
//!
//! `test/suite-net.janet` and the `net/` assertions in `test/suite-ev.janet`
//! drive real sockets over the loopback interface, which is what they are for.
//! Five things have no Janet spelling at all:
//!
//!  - **A socket address this machine cannot produce.** `soGetName` -- the
//!    decoder behind `net/address-unpack`, `net/localname` and `net/peername`
//!    -- switches on `sa_family`, and a Janet program can only hand it a family
//!    the host actually gave it. A host with no IPv6 route never reaches the
//!    `AF_INET6` arm, no host reaches the "unknown address family" arm, and a
//!    macOS host cannot construct Linux's abstract unix address, whose leading
//!    NUL is what selects the `'@'` branch. All four are a `@memset` and a
//!    `janet_abstract` away, because `janet_address_type` is a bare byte buffer
//!    with no callbacks -- which is also why the abstract can be built by hand
//!    at all.
//!  - **The order of `net_stream_methods`.** `JanetStream` is public and its
//!    `methods` member is the table, so the fourteen rows can be read back in
//!    order. From Janet only membership is visible.
//!  - **The failure paths that need an argument no Janet caller would write.**
//!    A raise is asserted here by its *message* rather than by its existence,
//!    which Part 11 recorded as the difference between a test and a tautology.
//!  - **A `sun_path` longer than the structure.** The truncating copy is
//!    invisible from Janet, which sees only the shortened name coming back.
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
//! ## What the migration changed
//!
//! **A refusal is a value.** The C contract armed `janet_contract_arm`, called
//! through `janet_contract_call_cfunction` and read `janet_contract_raised`;
//! this one calls the cfunction and reads the error. Those four shims had two
//! users left -- this file and `test/filewatch_core.c` -- and Part 21 took both.
//!
//! **The address structures come from `std.posix` rather than from the host
//! headers.** The C contract included `<netinet/in.h>` and built a
//! `struct sockaddr_in`; the subject reads one described by `net/abi.h`'s
//! translation of the same header, so the two descriptions were one. `std`'s
//! are written per platform and independently, which is what rules 8 and 20
//! ask for: the bytes this file lays down and the bytes the decoder reads are
//! now described by two different things, and a disagreement is a failure
//! rather than a silence. It also keeps the contract module free of a fourth
//! `@cImport` of the socket headers.

const std = @import("std");
const builtin = @import("builtin");
const types = @import("types");
const constants = @import("constants");
const c = @import("cabi");
const harness = @import("harness.zig");
const ev_stream = @import("subsystems").ev_stream;
const raise = @import("raise");

const subsystems = @import("subsystems");
const value = @import("subsystems").value;
const config = @import("config");
const gc_alloc = @import("subsystems").gc_alloc;
const core_env = @import("subsystems").env;
const wrap = @import("subsystems").value.wrap;
const args_core = @import("subsystems").args;
const vm_lifecycle = @import("subsystems").lifecycle;
const abstracts = @import("subsystems").value.abstracts;
const pp_describe = @import("subsystems").pp_describe;
const net_addr = subsystems.net;
const abstract_type = subsystems.abstract_type;

const assert = std.debug.assert;
const posix = std.posix;

const windows = builtin.os.tag == .windows;
const has_ipv6 = config.ipv6;

/// Ten on Windows, which reaches neither the unix-domain bindhost refusal nor
/// anything else this file guards. The count is asserted at the end, because a
/// case that silently stopped raising would otherwise pass.
const expected_raises: u32 = if (windows) 10 else 11;
var raises_seen: u32 = 0;

// ==========================================================================
// Refusals
// ==========================================================================

fn expectRaise(name: [*:0]const u8, argv: []types.Janet, message: []const u8) void {
    const r = harness.coreRaised(name, argv) orelse {
        std.debug.print("net_sockets: expected a raise saying: {s}\n", .{message});
        @panic("net_sockets: expected a raise, got a return");
    };
    assert(r.signal == constants.JANET_SIGNAL_ERROR);
    if (!r.says(message)) {
        std.debug.print("expected: {s}\n", .{message});
        std.debug.print("     got: {s}\n", .{pp_describe.toString(r.payload)});
        @panic("net_sockets: the raise carried another message");
    }
    raises_seen += 1;
}

/// For a message whose tail is the host's own wording -- `gai_strerror` and
/// `strerror` differ by platform and by libc, and pinning them would make this
/// contract a test of the C library -- or which names a stream and therefore
/// carries an address.
fn expectRaisePrefix(name: [*:0]const u8, argv: []types.Janet, prefix: []const u8) void {
    const r = harness.coreRaised(name, argv) orelse {
        std.debug.print("net_sockets: expected a raise starting: {s}\n", .{prefix});
        @panic("net_sockets: expected a raise, got a return");
    };
    assert(r.signal == constants.JANET_SIGNAL_ERROR);
    if (!r.beginsWith(prefix)) {
        std.debug.print("expected prefix: {s}\n", .{prefix});
        std.debug.print("            got: {s}\n", .{pp_describe.toString(r.payload)});
        @panic("net_sockets: the raise carried another message");
    }
    raises_seen += 1;
}

/// A cfunction that is expected to return, by the name the registry knows.
/// This is the pointer `janet_lib_net` registered, so it is the same abi a
/// Janet call would reach.
fn callCore(name: [*:0]const u8, argv: []types.Janet) types.Janet {
    return harness.callCore(name, argv) catch
        @panic("net_sockets: a call that should have returned raised");
}

// ==========================================================================
// Helpers
// ==========================================================================

/// Wrap `bytes` as a `core/socket-address`, which is what `net/address-unpack`
/// takes. The abstract has no callbacks, so this is the whole of building one.
fn addressOf(bytes: []const u8) types.Janet {
    const abst = abstracts.new(
        abstract_type.stored(&net_addr.addressType),
        bytes.len,
    ).?;
    const destination: [*]u8 = @ptrCast(abst);
    @memcpy(destination[0..bytes.len], bytes);
    return wrap.fromAbstract(abst);
}

fn asBytes(val: anytype) []const u8 {
    const bytes: [*]const u8 = @ptrCast(val);
    return bytes[0..@sizeOf(@TypeOf(val.*))];
}

fn unpack(address: types.Janet) types.Janet {
    var argv = [_]types.Janet{address};
    return callCore("net/address-unpack", &argv);
}

fn tupleIs2(val: types.Janet, host: []const u8, port: i32) bool {
    if (!harness.isType(val, constants.JANET_TUPLE)) return false;
    const t = wrap.toTuple(val);
    if (types.tupleHead(t).length != 2) return false;
    if (!harness.isType(t[0], constants.JANET_STRING)) return false;
    const text = wrap.toString(t[0]);
    const length: usize = @intCast(types.stringHead(text).length);
    if (!std.mem.eql(u8, text[0..length], host)) return false;
    return args_core.checkint(t[1]) != 0 and wrap.toInteger(t[1]) == port;
}

fn tupleIs1(val: types.Janet, path: []const u8) bool {
    if (!harness.isType(val, constants.JANET_TUPLE)) return false;
    const t = wrap.toTuple(val);
    if (types.tupleHead(t).length != 1) return false;
    if (!harness.isType(t[0], constants.JANET_STRING)) return false;
    const text = wrap.toString(t[0]);
    const length: usize = @intCast(types.stringHead(text).length);
    return std.mem.eql(u8, text[0..length], path);
}

fn pathLength(val: types.Janet) usize {
    assert(harness.isType(val, constants.JANET_TUPLE));
    const t = wrap.toTuple(val);
    assert(types.tupleHead(t).length == 1);
    return @intCast(types.stringHead(wrap.toString(t[0])).length);
}

// ==========================================================================
// Registration
// ==========================================================================

/// Every name `janet_lib_net` registers, in the order it registers them. The
/// order is not itself a contract -- a table has none -- but the list is: a
/// binding that stops being registered is what this catches, and Part 6
/// recorded that a registration table is the one place a cfunction can go
/// missing without a link error.
const net_bindings = [_][*:0]const u8{
    "net/address",     "net/listen",    "net/socket",    "net/accept",
    "net/accept-loop", "net/read",      "net/chunk",     "net/write",
    "net/send-to",     "net/recv-from", "net/flush",     "net/connect",
    "net/shutdown",    "net/peername",  "net/localname", "net/address-unpack",
    "net/setsockopt",
};

fn theRegistration() void {
    assert(net_bindings.len == 17);
    // `harness.core` asserts the binding resolves to a cfunction.
    for (net_bindings) |name| _ = harness.core(name);
}

// ==========================================================================
// Decoding an address
// ==========================================================================

/// An `AF_INET` address, laid out by `std.posix` and parsed by `std.Io.net`.
/// Zeroed first, exactly as the C contract's `memset` left it -- macOS's
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

fn theIpv4Decoding() void {
    {
        var sin = ip4("1.2.3.4", 8080);
        assert(tupleIs2(unpack(addressOf(asBytes(&sin))), "1.2.3.4", 8080));
    }

    // Port 0 and the wildcard address, which is what an unbound socket reports
    // and what `net/localname` returns before a bind.
    {
        var sin = ip4("0.0.0.0", 0);
        assert(tupleIs2(unpack(addressOf(asBytes(&sin))), "0.0.0.0", 0));
    }

    // The port is unsigned on the wire: 65535 must not come back negative.
    {
        var sin = ip4("255.255.255.255", 65535);
        assert(tupleIs2(unpack(addressOf(asBytes(&sin))), "255.255.255.255", 65535));
    }
}

fn theIpv6Decoding() void {
    {
        var sin6 = ip6("::1", 443);
        assert(tupleIs2(unpack(addressOf(asBytes(&sin6))), "::1", 443));
    }

    // The longest textual form there is, which is what sizes the decode
    // buffer: eight groups.
    {
        const text = "2001:db8:85a3:8d3:1319:8a2e:370:7348";
        var sin6 = ip6(text, 1);
        assert(tupleIs2(unpack(addressOf(asBytes(&sin6))), text, 1));
    }
}

fn theUnixDecoding() void {
    const path = "/tmp/janet-contract.sock";
    {
        var sun = std.mem.zeroes(posix.sockaddr.un);
        sun.family = posix.AF.UNIX;
        @memcpy(sun.path[0..path.len], path);
        assert(tupleIs1(unpack(addressOf(asBytes(&sun))), path));
    }

    // Linux's abstract namespace: the name starts at a NUL, and the decoder
    // shows that NUL as '@'. Only the *decoder* is per-platform-free -- this
    // address can be built and read back anywhere, which is the point of
    // building it by hand.
    {
        var sun = std.mem.zeroes(posix.sockaddr.un);
        sun.family = posix.AF.UNIX;
        const name = "abstract-name";
        sun.path[0] = 0;
        @memcpy(sun.path[1 .. 1 + name.len], name);
        assert(tupleIs1(unpack(addressOf(asBytes(&sun))), "@abstract-name"));
    }

    // A path that fills `sun_path` exactly, with no room for a terminator. The
    // decoder must stop at the end of the field rather than run past it.
    {
        var sun = std.mem.zeroes(posix.sockaddr.un);
        sun.family = posix.AF.UNIX;
        @memset(sun.path[0 .. sun.path.len - 1], 'x');
        assert(pathLength(unpack(addressOf(asBytes(&sun)))) == sun.path.len - 1);
    }
}

fn theUnknownFamily() void {
    // `AF_UNSPEC` is what a zeroed address reports, and nothing decodes it.
    var storage = std.mem.zeroes(posix.sockaddr.storage);
    storage.family = posix.AF.UNSPEC;
    var argv = [_]types.Janet{addressOf(asBytes(&storage))};
    expectRaise("net/address-unpack", &argv, "unknown address family");
}

// ==========================================================================
// Looking one up
// ==========================================================================

fn theAddressLookup() void {
    // A numeric host needs no resolver, so this is the one lookup that is the
    // same on every machine and in every network.
    var argv = [_]types.Janet{
        value.fromBytes("127.0.0.1", .string),
        harness.wrapInteger(9999),
        wrap.fromNil(),
        wrap.fromNil(),
    };
    assert(tupleIs2(unpack(callCore("net/address", argv[0..2])), "127.0.0.1", 9999));

    // The port may also be a string, which is the branch `janet_checkint` does
    // not take.
    argv[1] = value.fromBytes("9999", .string);
    assert(tupleIs2(unpack(callCore("net/address", argv[0..2])), "127.0.0.1", 9999));

    // `multi` truthy returns an array of them, and every element decodes.
    argv[1] = harness.wrapInteger(9999);
    argv[2] = value.fromBytes("stream", .keyword);
    argv[3] = wrap.fromTrue();
    {
        const all = callCore("net/address", argv[0..4]);
        assert(harness.isType(all, constants.JANET_ARRAY));
        const array = wrap.toArray(all);
        assert(array.*.count >= 1);
        for (0..@intCast(array.*.count)) |i| {
            assert(tupleIs2(unpack(array.*.data.?[i]), "127.0.0.1", 9999));
        }
    }

    // `:datagram` is the other socket type, and it resolves the same host.
    argv[2] = value.fromBytes("datagram", .keyword);
    argv[3] = wrap.fromFalse();
    assert(tupleIs2(unpack(callCore("net/address", argv[0..4])), "127.0.0.1", 9999));
}

/// **Three calls, three leaks, and they are the subject rather than an
/// oversight.** `FOUND.md` records that `cfun_net_sockaddr` returns from the
/// unix-domain branch without freeing the `addrinfo` it built, and the port
/// reproduces it; `port/leaks.sh` carries `expected_net_sockets=3` for exactly
/// these, so adding or removing a `net/address :unix` call here changes that
/// expectation and fixing the defect empties it.
fn theUnixAddressLookup() void {
    const path = "/tmp/janet-contract.sock";
    var argv = [_]types.Janet{
        value.fromBytes("unix", .keyword),
        value.fromBytes(path, .string),
        wrap.fromNil(),
        wrap.fromNil(),
    };
    assert(tupleIs1(unpack(callCore("net/address", argv[0..2])), path));

    // A name longer than `sun_path` is truncated rather than rejected, and the
    // terminator is kept -- so what comes back is one byte short of the field.
    // The C original spells this as `snprintf(.., sizeof path, "%s", ..)` and
    // nothing in Janet can see the difference between that and a copy that
    // overruns.
    {
        var big = std.mem.zeroes([512]u8);
        @memset(big[0 .. big.len - 1], 'a');
        argv[1] = value.fromBytes(std.mem.sliceTo(&big, 0), .string);
        const got = unpack(callCore("net/address", argv[0..2]));
        assert(pathLength(got) == @typeInfo(@FieldType(posix.sockaddr.un, "path")).array.len - 1);
    }

    // `multi` on a unix path is the one-element array branch.
    {
        argv[1] = value.fromBytes(path, .string);
        argv[2] = value.fromBytes("stream", .keyword);
        argv[3] = wrap.fromTrue();
        const all = callCore("net/address", argv[0..4]);
        assert(harness.isType(all, constants.JANET_ARRAY));
        const array = wrap.toArray(all);
        assert(array.*.count == 1);
        assert(tupleIs1(unpack(array.*.data.?[0]), path));
    }
}

// ==========================================================================
// The raise paths
// ==========================================================================

fn theArgumentFaults() void {
    // The socket type vocabulary: two keywords and nothing else.
    {
        var argv = [_]types.Janet{
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

    // A host the resolver cannot answer for. The tail is `gai_strerror`'s and
    // differs by libc, so only the prefix is pinned.
    {
        var argv = [_]types.Janet{
            value.fromBytes("no-such-host.invalid", .string),
            harness.wrapInteger(9999),
        };
        expectRaisePrefix("net/address", &argv, "could not get address info: ");
    }

    if (windows) return;

    // A unix domain address cannot also be bound to an outgoing interface, and
    // `net/connect` is where that is decided.
    //
    // **The path is short on purpose, and the reason is a defect.** `net.c`
    // released the address on this path with `freeaddrinfo`, which did not
    // allocate it -- the unix arm of the lookup returns a `janet_calloc`ed
    // `struct sockaddr_un` -- so the C implementation read `ai_canonname` and
    // `ai_next` out of `sun_path` and freed whatever it found. With a path long
    // enough to reach those offsets that is an abort, and measured on this
    // machine the threshold is between 11 and 26 characters. `FOUND.md` has the
    // entry and the reproducer; the port releases it correctly, so eleven
    // characters is what left the reinterpreted fields zero under both
    // implementations and it is kept because the *message* is what this asserts.
    var argv = [_]types.Janet{
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
    var listen_argv = [_]types.Janet{ value.fromBytes("127.0.0.1", .string), harness.wrapInteger(0) };
    const listener = callCore("net/listen", &listen_argv);
    assert(harness.isType(listener, constants.JANET_ABSTRACT));
    gc_alloc.gcroot(listener);
    defer _ = gc_alloc.gcunroot(listener);

    // Its local name is a real address, decoded by the same path the hand-built
    // ones above went through -- and the port is whatever the kernel picked, so
    // only the host is pinned.
    {
        var argv = [_]types.Janet{listener};
        const name = callCore("net/localname", &argv);
        assert(harness.isType(name, constants.JANET_TUPLE));
        const t = wrap.toTuple(name);
        assert(types.tupleHead(t).length == 2);
        assert(harness.stringIs(wrap.toString(t[0]), "127.0.0.1"));
        assert(args_core.checkint(t[1]) != 0 and wrap.toInteger(t[1]) > 0);
    }

    // A listener has no peer, and the message names the stream it failed on.
    {
        var argv = [_]types.Janet{listener};
        expectRaisePrefix("net/peername", &argv, "Failed to get peername on ");
    }

    // The method table, in order. `JanetStream` is public, so the rows can be
    // read back; from Janet only membership is visible.
    {
        const expected = [_][]const u8{
            "chunk",   "close",       "read",     "write",      "flush",
            "accept",  "accept-loop", "send-to",  "recv-from",  "evread",
            "evchunk", "evwrite",     "shutdown", "setsockopt",
        };
        const stream: *types.JanetStream = @ptrCast(@alignCast(wrap.toAbstract(listener)));
        const methods: [*]const types.JanetMethod = @ptrCast(@alignCast(stream.methods));
        for (expected, 0..) |name, i| {
            assert(methods[i].name != null);
            assert(std.mem.eql(u8, std.mem.span(methods[i].name.?), name));
            assert(methods[i].cfun != null);
        }
        assert(methods[expected.len].name == null);
        assert(methods[expected.len].cfun == null);
    }

    // `net/shutdown`'s vocabulary is three keywords.
    {
        var argv = [_]types.Janet{ listener, value.fromBytes("both", .keyword) };
        expectRaise("net/shutdown", &argv, "unexpected keyword :both");
    }

    // And the option table's, which is a name it does not hold.
    {
        var argv = [_]types.Janet{
            listener,
            value.fromBytes("so-nonsense", .keyword),
            wrap.fromTrue(),
        };
        expectRaise("net/setsockopt", &argv, "unknown socket option :so-nonsense");
    }

    // A handler that cannot be given the connection it is handed.
    {
        var handler = wrap.fromNil();
        assert(core_env.dostring(harness.coreEnv(), "(fn [] nil)", "contract", &handler) == 0);
        var argv = [_]types.Janet{ listener, handler };
        expectRaise("net/accept-loop", &argv, "handler function must take at least 1 argument");
    }

    // A closed stream is refused before any host call is made, and the two
    // name-reading cfunctions check it themselves rather than through
    // `janet_stream_flags`.
    {
        const stream: *types.JanetStream = @ptrCast(@alignCast(wrap.toAbstract(listener)));
        raise.reported(ev_stream.streamClose(stream));
        var one = [_]types.Janet{listener};
        expectRaise("net/localname", &one, "stream closed");
        expectRaise("net/peername", &one, "stream closed");
        // Everything else reports through `janet_stream_flags`, whose wording
        // belongs to the event loop rather than to this subsystem.
        var shutdown_argv = [_]types.Janet{ listener, value.fromBytes("rw", .keyword) };
        expectRaise("net/shutdown", &shutdown_argv, "stream is closed");
    }
}

// ==========================================================================
// An unbound socket
// ==========================================================================

fn theUnboundSocket() void {
    // `net/socket` binds nothing, so its local name is the wildcard address on
    // port zero -- the one decode a live socket cannot otherwise produce.
    {
        var argv = [_]types.Janet{ value.fromBytes("datagram", .keyword), value.fromBytes("ipv4", .keyword) };
        const sock = callCore("net/socket", &argv);
        assert(harness.isType(sock, constants.JANET_ABSTRACT));
        var name_argv = [_]types.Janet{sock};
        assert(tupleIs2(callCore("net/localname", &name_argv), "0.0.0.0", 0));
        raise.reported(ev_stream.streamClose(@ptrCast(@alignCast(wrap.toAbstract(sock)))));
    }

    // No arguments at all is a stream socket in whatever family the resolver
    // prefers, which is the default path through the family lookup.
    {
        var none = [_]types.Janet{};
        const sock = callCore("net/socket", &none);
        assert(harness.isType(sock, constants.JANET_ABSTRACT));
        raise.reported(ev_stream.streamClose(@ptrCast(@alignCast(wrap.toAbstract(sock)))));
    }
}

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

    assert(raises_seen == expected_raises);
    std.debug.print("net_sockets contract ok ({d} raises)\n", .{raises_seen});
}
