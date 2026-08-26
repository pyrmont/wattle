#ifndef JANET_ZIG_NET_ABI_H
#define JANET_ZIG_NET_ABI_H

/* The host socket headers `net.c` works through, prepared for Zig's
 * translate-c.
 *
 * One of the three host translations left in the tree, and it is here for the
 * reason `os/abi.h` gives for the first of them: nothing declared *here*
 * crosses a subsystem boundary. A `struct addrinfo` lives for the length of
 * one cfunction, and the one socket address that outlives its call is
 * `janet_address_type`'s abstract, which is a byte buffer both sides treat as
 * opaque. Nothing Janet's own -- a `JanetStream *`, a `Janet` -- appears in
 * this translation at all; `types.zig` owns those and every Zig file shares
 * it. The rule this used to state against `abi.zig`'s shared `@cImport`
 * survives its subject: Phase 12 increment 5f retired that translation with
 * `janet.h`, so what is left is three host headers with no Janet type between
 * them.
 *
 * Unlike `os/abi.h`, this one *does* include the Windows headers rather than
 * restating what it needs in Zig. `ev_stream.zig` took the other route and
 * declared `WSARecvFrom` and its kin by hand, because what it needed was four
 * calls and one structure. What `net.c` needs from Winsock is forty integer
 * constants whose values differ from the POSIX ones -- `SOL_SOCKET` is
 * `0xffff` against Linux's `1`, `AF_INET6` is 23 against 30 on macOS and 10 on
 * Linux -- and forty hand-copied magic numbers on a platform this project
 * builds but does not run is a worse bet than a translation the matrix
 * compiles. Measured on 2026-08-23, every declaration `net_sockets.zig` names
 * survives the translation for `x86_64-windows-gnu` except `WSAID_CONNECTEX`,
 * which is a brace initializer; that one is restated in `net/abi.zig`.
 *
 * `janet_features.h` comes first, as it must before any system header.
 */

#include "janet_features.h"

/* Aro -- the translate-c front end in Zig 0.16 -- predefines `__unix__`,
 * `unix` and `__unix` for the mingw targets and clang does not, so a `@cImport`
 * of this file and a compilation of the same target disagree about the
 * predefine unless it is cleared. `janet.h` was where that first bit, in Phase
 * 10 Part 12 -- it tested its Unix chain before its Windows one, so the
 * translation for `x86_64-windows-gnu` said `JANET_POSIX` where the
 * compilation said `JANET_WINDOWS`, and `JanetHandle` came out `int` rather
 * than `void *`. `FOUND.md` records it.
 *
 * **The header is gone with Phase 12 increment 5f and this stays**, in all
 * three host translations, because what it protects is not `janet.h`: every
 * system header included below is read by translate-c and compiled by clang,
 * and the guard is what makes those two agree. The platform chains in this
 * file put their Windows arm first as well, which is belt to this braces --
 * the two corrections are independent and both are cheap. */
#if defined(_WIN32) || defined(WIN32)
#undef __unix__
#undef unix
#undef __unix
#endif

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

/* Whether `serverify_socket` may ask for `SO_REUSEPORT`. `net.c` spells this
 * `#if defined(SO_REUSEPORT) && !JANET_GNU_HURD`, and the Hurd half cannot be
 * an `@hasDecl` because it is a platform test rather than a declaration. The
 * enumeration is C's and stays C's; Zig reads the answer.
 *
 * `JANET_GNU_HURD` was `janet.h`'s name for `__gnu_hurd__`, one line above
 * where it defined it. Increment 5f retired the header, so the predefine is
 * tested directly -- which is what `janet.h` did. */
#if defined(SO_REUSEPORT) && !defined(__gnu_hurd__)
#define JANET_ZIG_REUSEPORT 1
#else
#define JANET_ZIG_REUSEPORT 0
#endif

/* Whether an `IP_MULTICAST_TTL` value is passed as `unsigned char` rather than
 * as `int`. `net.c` decides this with `#if defined(JANET_BSD) ||
 * defined(JANET_ILLUMOS)`, and the same rule applies: the enumeration stays in
 * C. Those two were `janet.h`'s names for the four BSD predefines and for
 * `__illumos__`; they are spelled out here for the reason above. Apple is not
 * among them, in `janet.h` or here -- `JANET_APPLE` is its own name and
 * `net.c` does not test it in this clause. */
#if defined(__FreeBSD__) || defined(__DragonFly__) || defined(__NetBSD__) \
    || defined(__OpenBSD__) || defined(__illumos__)
#define JANET_ZIG_MULTICAST_TTL_CHAR 1
#else
#define JANET_ZIG_MULTICAST_TTL_CHAR 0
#endif

#endif /* JANET_ZIG_NET_ABI_H */
