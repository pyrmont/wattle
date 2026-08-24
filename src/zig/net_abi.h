#ifndef JANET_ZIG_NET_ABI_H
#define JANET_ZIG_NET_ABI_H

/* The host socket headers `net.c` works through, prepared for Zig's
 * translate-c.
 *
 * This is the third translation in the tree and it is here for the reason
 * `os_abi.h` gives for the second. `abi.zig` translates Janet's own headers
 * and every Zig object shares it, so that a `JanetStream *` produced by one is
 * the same Zig type as a `JanetStream *` consumed by another. Nothing declared
 * *here* crosses a subsystem boundary: a `struct addrinfo` lives for the
 * length of one cfunction, and the one socket address that outlives its call
 * is `janet_address_type`'s abstract, which is a byte buffer both sides treat
 * as opaque -- `ev.c` and `ev_stream.zig` already pass it as `void *`. Adding
 * `<netdb.h>` and `<winsock2.h>` to `abi.zig` would put them into the
 * translation every Zig object in the tree shares, to serve two files.
 *
 * Unlike `os_abi.h`, this one *does* include the Windows headers rather than
 * restating what it needs in Zig. `ev_stream.zig` took the other route and
 * declared `WSARecvFrom` and its kin by hand, because what it needed was four
 * calls and one structure. What `net.c` needs from Winsock is forty integer
 * constants whose values differ from the POSIX ones -- `SOL_SOCKET` is
 * `0xffff` against Linux's `1`, `AF_INET6` is 23 against 30 on macOS and 10 on
 * Linux -- and forty hand-copied magic numbers on a platform this project
 * builds but does not run is a worse bet than a translation the matrix
 * compiles. Measured on 2026-08-23, every declaration `net_sockets.zig` names
 * survives the translation for `x86_64-windows-gnu` except `WSAID_CONNECTEX`,
 * which is a brace initializer; that one is restated in `net_abi.zig`.
 *
 * `janet_features.h` comes first, as it must before any system header.
 */

#include "janet_features.h"

/* Aro -- the translate-c front end in Zig 0.16 -- predefines `__unix__`,
 * `unix` and `__unix` for the mingw targets as well as `_WIN32`. `os_abi.h`
 * and `state_abi.h` carry the full reasoning: the correction is a fact about
 * the tool rather than about the C build, and `FOUND.md` records it. Here it
 * decides which of the two include sets below is taken, so it is as
 * load-bearing as it is there. */
#if defined(_WIN32) || defined(WIN32)
#undef __unix__
#undef unix
#undef __unix
#endif

/* `janet.h` is here for its *platform* names only -- `JANET_BSD`,
 * `JANET_ILLUMOS` and `JANET_GNU_HURD`, which the two restatements at the
 * bottom of this file test exactly as `net.c` does. Nothing in `net_abi.zig`
 * reads a Janet type out of this translation; those come from `abi.zig`, which
 * is shared, and that is what the single-translation rule is about. Restating
 * the three platform chains here instead was the alternative and is the
 * duplication these ports exist to remove. */
#include <janet.h>

#include <errno.h>
#include <string.h>

#ifdef _WIN32
#include <winsock2.h>
#include <windows.h>
#include <ws2tcpip.h>
#include <mswsock.h>
#else
#include <arpa/inet.h>
#include <unistd.h>
#include <signal.h>
#include <sys/ioctl.h>
#include <sys/types.h>
#include <sys/socket.h>
#include <sys/un.h>
#include <netinet/in.h>
#include <netinet/tcp.h>
#include <netdb.h>
#include <fcntl.h>
#endif

/* `net.c` supplies 0 where the platform has no `MSG_NOSIGNAL`, which is every
 * BSD including macOS. Restated with a value so that translate-c surfaces it
 * and a Zig caller does not have to repeat the condition. */
#ifndef MSG_NOSIGNAL
#define JANET_ZIG_MSG_NOSIGNAL 0
#else
#define JANET_ZIG_MSG_NOSIGNAL MSG_NOSIGNAL
#endif

/* Whether this build has IPv6. `JANET_NO_IPV6` is defined with no value, which
 * translate-c does not surface; `state_abi.h` restates five of `janet.h`'s
 * flags for the same reason and this is the sixth. */
#ifdef JANET_NO_IPV6
#define JANET_ZIG_HAS_IPV6 0
#else
#define JANET_ZIG_HAS_IPV6 1
#endif

/* Whether `serverify_socket` may ask for `SO_REUSEPORT`. `net.c` spells this
 * `#if defined(SO_REUSEPORT) && !JANET_GNU_HURD`, and the Hurd half cannot be
 * an `@hasDecl` because it is a platform test rather than a declaration. The
 * enumeration is C's and stays C's; Zig reads the answer. */
#if defined(SO_REUSEPORT) && !JANET_GNU_HURD
#define JANET_ZIG_REUSEPORT 1
#else
#define JANET_ZIG_REUSEPORT 0
#endif

/* Whether an `IP_MULTICAST_TTL` value is passed as `unsigned char` rather than
 * as `int`. `net.c` decides this with `#if defined(JANET_BSD) ||
 * defined(JANET_ILLUMOS)`, which are `janet.h`'s own platform names, and the
 * same rule applies: the enumeration stays in C. */
#if defined(JANET_BSD) || defined(JANET_ILLUMOS)
#define JANET_ZIG_MULTICAST_TTL_CHAR 1
#else
#define JANET_ZIG_MULTICAST_TTL_CHAR 0
#endif

#endif /* JANET_ZIG_NET_ABI_H */
