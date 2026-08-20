/* Behavioral contract for the socket layer, run against whichever
 * implementation the build selected (`-Dnet-sockets=c` or the Zig default).
 *
 * ## What the Janet suites cannot reach
 *
 * `test/suite-net.janet` and the `net/` assertions in `test/suite-ev.janet`
 * drive real sockets over the loopback interface, which is what they are for.
 * Five things have no Janet spelling at all:
 *
 *  - **A socket address this machine cannot produce.** `janet_so_getname` --
 *    the decoder behind `net/address-unpack`, `net/localname` and
 *    `net/peername` -- switches on `sa_family`, and a Janet program can only
 *    hand it a family the host actually gave it. A host with no IPv6 route
 *    never reaches the `AF_INET6` arm, no host reaches the "unknown address
 *    family" arm, and a macOS host cannot construct Linux's abstract unix
 *    address, whose leading NUL is what selects the `'@'` branch. All four are
 *    a `memset` and a `janet_abstract` away from C, because `janet_address_type`
 *    is a bare byte buffer with no callbacks -- which is also why the abstract
 *    can be built by hand at all.
 *  - **`janet_address_type` as a symbol.** It is one of four things this file
 *    exports; the others are `janet_lib_net` and the init/deinit pair, which
 *    `janet_init` already calls.
 *  - **The order of `net_stream_methods`.** `JanetStream` is public and its
 *    `methods` member is the table, so the fourteen rows can be read back in
 *    order. From Janet only membership is visible.
 *  - **The failure paths that need an argument no Janet caller would write.**
 *    A raise is asserted here by its *message* rather than by its existence,
 *    which Part 11 recorded as the difference between a test and a tautology.
 *  - **A `sun_path` longer than the structure.** The truncating copy is
 *    invisible from Janet, which sees only the shortened name coming back.
 *
 * ## What it deliberately does not do
 *
 * It does not open a connection. `net/connect` and `net/accept` end by
 * suspending the calling fiber on the event loop, so driving either from a C
 * contract means running the loop, and a contract that waits on the kernel is
 * a contract that hangs when it is wrong. `test/suite-ev.janet` runs them
 * inside the loop, where they belong. What is checked here is everything
 * before the suspension: the argument decoding, the address lookup, the socket
 * setup and every raise on the way.
 *
 * ## The two faces
 *
 * Phase 10's acceptance list requires the C face and the Zig face of a
 * converted symbol to be tested separately. This increment converts no
 * raise-capable *exported* symbol: every one of `net.c`'s raises is inside a
 * cfunction, and a cfunction is a C face already -- `Face(...).cfun` catches
 * the error and calls `raise.deliverToC()`. So the check is met by calling the
 * registered cfunction pointer directly, which is what `call_core` does, and
 * there is no second face to drift from it. */

#include <assert.h>
#include <stdint.h>
#include <stdio.h>
#include <string.h>
#include "features.h"
#include <janet.h>

#include "support.h"
#include "state.h"

#ifndef JANET_WINDOWS
#include <sys/socket.h>
#include <sys/un.h>
#include <netinet/in.h>
#include <arpa/inet.h>
#else
#include <winsock2.h>
#include <ws2tcpip.h>
#endif

/* `src/core/util.h`, which is internal: declared rather than included so that
 * the contract depends only on the ABI it exercises. */
extern const JanetAbstractType janet_address_type;

/* ------------------------------------------------------- raise assertions */

static int panics_fired = 0;
#ifdef JANET_WINDOWS
#define EXPECTED_PANICS 10
#else
#define EXPECTED_PANICS 11
#endif

/* The message is checked, not just the fact of a raise. `test/io_core.c` has
 * the reasoning: a contract that only asks "did it raise" leaves every message
 * literal untested. */
#define EXPECT_PANIC_MSG(expr, text) do { \
    JanetTryState _state; \
    int _raised = 0; \
    JanetSignal _sig = JANET_SIGNAL_OK; \
    janet_try_init(&_state); \
    janet_contract_arm(); \
    (void)(expr); \
    _raised = janet_contract_raised(); \
    if (_raised) _sig = janet_contract_signal(); \
    janet_restore(&_state); \
    assert(_raised && "expected a panic, got a return"); \
    assert(_sig == JANET_SIGNAL_ERROR); \
    assert(janet_checktype(_state.payload, JANET_STRING)); \
    assert(!janet_cstrcmp(janet_unwrap_string(_state.payload), (text))); \
    panics_fired++; \
} while (0)

/* For a message whose tail is the host's own wording -- `gai_strerror` and
 * `strerror` differ by platform and by libc, and pinning them would make this
 * contract a test of the C library. */
#define EXPECT_PANIC_PREFIX(expr, text) do { \
    JanetTryState _state; \
    int _raised = 0; \
    JanetSignal _sig = JANET_SIGNAL_OK; \
    janet_try_init(&_state); \
    janet_contract_arm(); \
    (void)(expr); \
    _raised = janet_contract_raised(); \
    if (_raised) _sig = janet_contract_signal(); \
    janet_restore(&_state); \
    assert(_raised && "expected a panic, got a return"); \
    assert(_sig == JANET_SIGNAL_ERROR); \
    assert(janet_checktype(_state.payload, JANET_STRING)); \
    assert((size_t) janet_string_length(janet_unwrap_string(_state.payload)) >= strlen(text)); \
    assert(!memcmp(janet_unwrap_string(_state.payload), (text), strlen(text))); \
    panics_fired++; \
} while (0)

/* Call a core cfunction by name. This is the pointer `janet_lib_net`
 * registered, so it is the same face a Janet call would reach. */
static Janet call_core(const char *name, int32_t argc, Janet *argv) {
    Janet fun = janet_resolve_core(name);
    assert(janet_checktype(fun, JANET_CFUNCTION));
    return janet_contract_call_cfunction(janet_unwrap_cfunction(fun), argc, argv);
}

/* ------------------------------------------------------------ helpers */

/* Wrap `len` bytes as a `core/socket-address`, which is what
 * `net/address-unpack` takes. The abstract has no callbacks, so this is the
 * whole of building one. */
static Janet address_of(const void *bytes, size_t len) {
    void *abst = janet_abstract(&janet_address_type, len);
    memcpy(abst, bytes, len);
    return janet_wrap_abstract(abst);
}

static int tuple_is_2(Janet v, const char *host, int32_t port) {
    if (!janet_checktype(v, JANET_TUPLE)) return 0;
    const Janet *t = janet_unwrap_tuple(v);
    if (janet_tuple_length(t) != 2) return 0;
    if (!janet_checktype(t[0], JANET_STRING)) return 0;
    if (janet_cstrcmp(janet_unwrap_string(t[0]), host)) return 0;
    return janet_checkint(t[1]) && janet_unwrap_integer(t[1]) == port;
}

static int tuple_is_1(Janet v, const char *path) {
    if (!janet_checktype(v, JANET_TUPLE)) return 0;
    const Janet *t = janet_unwrap_tuple(v);
    if (janet_tuple_length(t) != 1) return 0;
    if (!janet_checktype(t[0], JANET_STRING)) return 0;
    return 0 == janet_cstrcmp(janet_unwrap_string(t[0]), path);
}

static Janet unpack(Janet address) {
    Janet argv[1] = { address };
    return call_core("net/address-unpack", 1, argv);
}

/* ------------------------------------------------------- registration */

/* Every name `janet_lib_net` registers, in the order it registers them. The
 * order is not itself a contract -- a table has none -- but the list is: a
 * binding that stops being registered is what this catches, and Part 6
 * recorded that a registration table is the one place a cfunction can go
 * missing without a link error. */
static const char *const net_bindings[] = {
    "net/address", "net/listen", "net/socket", "net/accept", "net/accept-loop",
    "net/read", "net/chunk", "net/write", "net/send-to", "net/recv-from",
    "net/flush", "net/connect", "net/shutdown", "net/peername", "net/localname",
    "net/address-unpack", "net/setsockopt",
};

static void test_registration(void) {
    size_t count = sizeof(net_bindings) / sizeof(net_bindings[0]);
    assert(count == 17);
    for (size_t i = 0; i < count; i++) {
        Janet fun = janet_resolve_core(net_bindings[i]);
        assert(janet_checktype(fun, JANET_CFUNCTION));
    }
}

/* -------------------------------------------------- decoding an address */

static void test_decode_ipv4(void) {
    struct sockaddr_in sin;
    memset(&sin, 0, sizeof(sin));
    sin.sin_family = AF_INET;
    sin.sin_port = htons(8080);
    assert(1 == inet_pton(AF_INET, "1.2.3.4", &sin.sin_addr));
    assert(tuple_is_2(unpack(address_of(&sin, sizeof(sin))), "1.2.3.4", 8080));

    /* Port 0 and the wildcard address, which is what an unbound socket
     * reports and what `net/localname` returns before a bind. */
    memset(&sin, 0, sizeof(sin));
    sin.sin_family = AF_INET;
    assert(tuple_is_2(unpack(address_of(&sin, sizeof(sin))), "0.0.0.0", 0));

    /* The port is unsigned on the wire: 65535 must not come back negative. */
    memset(&sin, 0, sizeof(sin));
    sin.sin_family = AF_INET;
    sin.sin_port = htons(65535);
    assert(1 == inet_pton(AF_INET, "255.255.255.255", &sin.sin_addr));
    assert(tuple_is_2(unpack(address_of(&sin, sizeof(sin))), "255.255.255.255", 65535));
}

#ifndef JANET_NO_IPV6
static void test_decode_ipv6(void) {
    struct sockaddr_in6 sin6;
    memset(&sin6, 0, sizeof(sin6));
    sin6.sin6_family = AF_INET6;
    sin6.sin6_port = htons(443);
    assert(1 == inet_pton(AF_INET6, "::1", &sin6.sin6_addr));
    assert(tuple_is_2(unpack(address_of(&sin6, sizeof(sin6))), "::1", 443));

    /* The longest textual form there is, which is what sizes the decode
     * buffer: eight groups plus an embedded IPv4 tail. */
    memset(&sin6, 0, sizeof(sin6));
    sin6.sin6_family = AF_INET6;
    sin6.sin6_port = htons(1);
    assert(1 == inet_pton(AF_INET6, "2001:db8:85a3:8d3:1319:8a2e:370:7348", &sin6.sin6_addr));
    assert(tuple_is_2(unpack(address_of(&sin6, sizeof(sin6))),
                      "2001:db8:85a3:8d3:1319:8a2e:370:7348", 1));
}
#endif

#ifndef JANET_WINDOWS
static void test_decode_unix(void) {
    struct sockaddr_un sun;
    memset(&sun, 0, sizeof(sun));
    sun.sun_family = AF_UNIX;
    memcpy(sun.sun_path, "/tmp/janet-contract.sock", strlen("/tmp/janet-contract.sock"));
    assert(tuple_is_1(unpack(address_of(&sun, sizeof(sun))), "/tmp/janet-contract.sock"));

    /* Linux's abstract namespace: the name starts at a NUL, and the decoder
     * shows that NUL as '@'. Only the *decoder* is per-platform-free -- this
     * address can be built and read back anywhere, which is the point of
     * building it by hand. */
    memset(&sun, 0, sizeof(sun));
    sun.sun_family = AF_UNIX;
    sun.sun_path[0] = '\0';
    memcpy(sun.sun_path + 1, "abstract-name", strlen("abstract-name"));
    assert(tuple_is_1(unpack(address_of(&sun, sizeof(sun))), "@abstract-name"));

    /* A path that fills `sun_path` exactly, with no room for a terminator.
     * The decoder must stop at the end of the field rather than run past it. */
    memset(&sun, 0, sizeof(sun));
    sun.sun_family = AF_UNIX;
    memset(sun.sun_path, 'x', sizeof(sun.sun_path) - 1);
    {
        Janet got = unpack(address_of(&sun, sizeof(sun)));
        assert(janet_checktype(got, JANET_TUPLE));
        const Janet *t = janet_unwrap_tuple(got);
        assert(janet_tuple_length(t) == 1);
        assert(janet_string_length(janet_unwrap_string(t[0])) ==
               (int32_t)(sizeof(sun.sun_path) - 1));
    }
}
#endif

static void test_decode_unknown_family(void) {
    /* `AF_UNSPEC` is what a zeroed address reports, and nothing decodes it. */
    struct sockaddr_storage ss;
    memset(&ss, 0, sizeof(ss));
    ss.ss_family = AF_UNSPEC;
    EXPECT_PANIC_MSG(unpack(address_of(&ss, sizeof(ss))), "unknown address family");
}

/* ------------------------------------------------------ looking one up */

static void test_address_lookup(void) {
    Janet argv[4];

    /* A numeric host needs no resolver, so this is the one lookup that is the
     * same on every machine and in every network. */
    argv[0] = janet_cstringv("127.0.0.1");
    argv[1] = janet_wrap_integer(9999);
    assert(tuple_is_2(unpack(call_core("net/address", 2, argv)), "127.0.0.1", 9999));

    /* The port may also be a string, which is the branch `janet_checkint`
     * does not take. */
    argv[1] = janet_cstringv("9999");
    assert(tuple_is_2(unpack(call_core("net/address", 2, argv)), "127.0.0.1", 9999));

    /* `multi` truthy returns an array of them, and every element decodes. */
    argv[1] = janet_wrap_integer(9999);
    argv[2] = janet_ckeywordv("stream");
    argv[3] = janet_wrap_true();
    {
        Janet all = call_core("net/address", 4, argv);
        assert(janet_checktype(all, JANET_ARRAY));
        JanetArray *arr = janet_unwrap_array(all);
        assert(arr->count >= 1);
        for (int32_t i = 0; i < arr->count; i++) {
            assert(tuple_is_2(unpack(arr->data[i]), "127.0.0.1", 9999));
        }
    }

    /* :datagram is the other socket type, and it resolves the same host. */
    argv[2] = janet_ckeywordv("datagram");
    argv[3] = janet_wrap_false();
    assert(tuple_is_2(unpack(call_core("net/address", 4, argv)), "127.0.0.1", 9999));
}

#ifndef JANET_WINDOWS
static void test_address_unix(void) {
    Janet argv[2];
    argv[0] = janet_ckeywordv("unix");
    argv[1] = janet_cstringv("/tmp/janet-contract.sock");
    assert(tuple_is_1(unpack(call_core("net/address", 2, argv)), "/tmp/janet-contract.sock"));

    /* A name longer than `sun_path` is truncated rather than rejected, and
     * the terminator is kept -- so what comes back is one byte short of the
     * field. The C original spells this as `snprintf(.., sizeof path, "%s", ..)`
     * and nothing in Janet can see the difference between that and a copy that
     * overruns. */
    {
        char big[512];
        memset(big, 'a', sizeof(big) - 1);
        big[sizeof(big) - 1] = '\0';
        argv[1] = janet_cstringv(big);
        Janet got = unpack(call_core("net/address", 2, argv));
        assert(janet_checktype(got, JANET_TUPLE));
        const Janet *t = janet_unwrap_tuple(got);
        assert(janet_string_length(janet_unwrap_string(t[0])) ==
               (int32_t)(sizeof(((struct sockaddr_un *)0)->sun_path) - 1));
    }

    /* `multi` on a unix path is the one-element array branch. */
    {
        Janet unix_argv[4];
        unix_argv[0] = janet_ckeywordv("unix");
        unix_argv[1] = janet_cstringv("/tmp/janet-contract.sock");
        unix_argv[2] = janet_ckeywordv("stream");
        unix_argv[3] = janet_wrap_true();
        Janet all = call_core("net/address", 4, unix_argv);
        assert(janet_checktype(all, JANET_ARRAY));
        assert(janet_unwrap_array(all)->count == 1);
        assert(tuple_is_1(unpack(janet_unwrap_array(all)->data[0]),
                          "/tmp/janet-contract.sock"));
    }
}
#endif

/* ------------------------------------------------------ the raise paths */

static void test_argument_faults(void) {
    Janet argv[3];

    /* The socket type vocabulary: two keywords and nothing else. */
    argv[0] = janet_cstringv("127.0.0.1");
    argv[1] = janet_wrap_integer(9999);
    argv[2] = janet_ckeywordv("tcp");
    EXPECT_PANIC_MSG(call_core("net/address", 3, argv),
                     "expected socket type as :stream or :datagram, got :tcp");

    /* A host the resolver cannot answer for. The tail is `gai_strerror`'s and
     * differs by libc, so only the prefix is pinned. */
    argv[0] = janet_cstringv("no-such-host.invalid");
    argv[1] = janet_wrap_integer(9999);
    EXPECT_PANIC_PREFIX(call_core("net/address", 2, argv),
                        "could not get address info: ");

#ifndef JANET_WINDOWS
    /* A unix domain address cannot also be bound to an outgoing interface,
     * and `net/connect` is where that is decided.
     *
     * **The path is short on purpose, and the reason is a defect.** `net.c`
     * releases the address on this path with `freeaddrinfo`, which did not
     * allocate it -- the unix arm of `janet_get_addrinfo` returns a
     * `janet_calloc`ed `struct sockaddr_un` -- so the C implementation reads
     * `ai_canonname` and `ai_next` out of `sun_path` and frees whatever it
     * finds. With a path long enough to reach those offsets that is an abort,
     * and measured on this machine the threshold is between 11 and 26
     * characters. `FOUND.md` has the entry and the reproducer; the port
     * releases it correctly, so the two implementations differ here by
     * design and a contract cannot see its selector. Eleven characters is
     * what leaves the reinterpreted fields zero on both libcs, which is what
     * lets this assert the *message* under both arms. */
    {
        Janet connect_argv[5];
        connect_argv[0] = janet_ckeywordv("unix");
        connect_argv[1] = janet_cstringv("/tmp/a.sock");
        connect_argv[2] = janet_ckeywordv("stream");
        connect_argv[3] = janet_cstringv("127.0.0.1");
        connect_argv[4] = janet_wrap_integer(0);
        EXPECT_PANIC_MSG(call_core("net/connect", 5, connect_argv),
                         "bindhost not supported for unix domain sockets");
    }
#endif
}

static void test_stream_faults(void) {
    Janet argv[3];
    Janet listener;

    /* A listener is the one socket a contract can make without entering the
     * loop: `net/listen` returns before anything suspends. */
    argv[0] = janet_cstringv("127.0.0.1");
    argv[1] = janet_wrap_integer(0);
    listener = call_core("net/listen", 2, argv);
    assert(janet_checktype(listener, JANET_ABSTRACT));

    /* Its local name is a real address, decoded by the same path the
     * hand-built ones above went through -- and the port is whatever the
     * kernel picked, so only the host is pinned. */
    {
        Janet name_argv[1] = { listener };
        Janet name = call_core("net/localname", 1, name_argv);
        assert(janet_checktype(name, JANET_TUPLE));
        const Janet *t = janet_unwrap_tuple(name);
        assert(janet_tuple_length(t) == 2);
        assert(!janet_cstrcmp(janet_unwrap_string(t[0]), "127.0.0.1"));
        assert(janet_checkint(t[1]) && janet_unwrap_integer(t[1]) > 0);
    }

    /* A listener has no peer, and the message names the stream it failed on. */
    {
        Janet peer_argv[1] = { listener };
        EXPECT_PANIC_PREFIX(call_core("net/peername", 1, peer_argv),
                            "Failed to get peername on ");
    }

    /* The method table, in order. `JanetStream` is public, so the rows can be
     * read back; from Janet only membership is visible. */
    {
        static const char *const expected[] = {
            "chunk", "close", "read", "write", "flush", "accept", "accept-loop",
            "send-to", "recv-from", "evread", "evchunk", "evwrite", "shutdown",
            "setsockopt",
        };
        JanetStream *stream = janet_unwrap_abstract(listener);
        const JanetMethod *methods = (const JanetMethod *) stream->methods;
        size_t count = sizeof(expected) / sizeof(expected[0]);
        for (size_t i = 0; i < count; i++) {
            assert(methods[i].name != NULL);
            assert(!strcmp(methods[i].name, expected[i]));
            assert(methods[i].cfun != NULL);
        }
        assert(methods[count].name == NULL);
        assert(methods[count].cfun == NULL);
    }

    /* `net/shutdown`'s vocabulary is three keywords. */
    argv[0] = listener;
    argv[1] = janet_ckeywordv("both");
    EXPECT_PANIC_MSG(call_core("net/shutdown", 2, argv), "unexpected keyword :both");

    /* And the option table's, which is a name it does not hold. */
    argv[1] = janet_ckeywordv("so-nonsense");
    argv[2] = janet_wrap_true();
    EXPECT_PANIC_MSG(call_core("net/setsockopt", 3, argv),
                     "unknown socket option :so-nonsense");

    /* A handler that cannot be given the connection it is handed. */
    {
        Janet fun;
        assert(0 == janet_dostring(janet_core_env(NULL),
                                   "(fn [] nil)", "contract", &fun));
        argv[1] = fun;
        EXPECT_PANIC_MSG(call_core("net/accept-loop", 2, argv),
                         "handler function must take at least 1 argument");
    }

    /* A closed stream is refused before any host call is made, and the two
     * name-reading cfunctions check it themselves rather than through
     * `janet_stream_flags`. */
    {
        Janet close_argv[1] = { listener };
        JanetStream *stream = janet_unwrap_abstract(listener);
        janet_stream_close(stream);
        EXPECT_PANIC_MSG(call_core("net/localname", 1, close_argv), "stream closed");
        EXPECT_PANIC_MSG(call_core("net/peername", 1, close_argv), "stream closed");
        /* Everything else reports through `janet_stream_flags`, whose wording
         * belongs to `-Dev-loop` rather than to this increment. */
        argv[1] = janet_ckeywordv("rw");
        EXPECT_PANIC_MSG(call_core("net/shutdown", 2, argv), "stream is closed");
    }
}

/* ------------------------------------------------- an unbound socket */

static void test_socket(void) {
    Janet argv[2];

    /* `net/socket` binds nothing, so its local name is the wildcard address
     * on port zero -- the one decode a live socket cannot otherwise produce. */
    argv[0] = janet_ckeywordv("datagram");
    argv[1] = janet_ckeywordv("ipv4");
    {
        Janet sock = call_core("net/socket", 2, argv);
        assert(janet_checktype(sock, JANET_ABSTRACT));
        Janet name_argv[1] = { sock };
        assert(tuple_is_2(call_core("net/localname", 1, name_argv), "0.0.0.0", 0));
        janet_stream_close(janet_unwrap_abstract(sock));
    }

    /* No arguments at all is a stream socket in whatever family the resolver
     * prefers, which is the default path through `net_get_address_family`. */
    {
        Janet sock = call_core("net/socket", 0, NULL);
        assert(janet_checktype(sock, JANET_ABSTRACT));
        janet_stream_close(janet_unwrap_abstract(sock));
    }
}

void net_sockets_contract(void) {
    janet_init();

    test_registration();
    test_decode_ipv4();
#ifndef JANET_NO_IPV6
    test_decode_ipv6();
#endif
#ifndef JANET_WINDOWS
    test_decode_unix();
#endif
    test_decode_unknown_family();
    test_address_lookup();
#ifndef JANET_WINDOWS
    test_address_unix();
#endif
    test_argument_faults();
    test_stream_faults();
    test_socket();

    assert(panics_fired == EXPECTED_PANICS);

    janet_deinit();
    printf("net_sockets contract ok\n");
}
