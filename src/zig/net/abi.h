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
  * opaque. Nothing Janet's own -- a `JanetStream *`, a `Value` -- appears in
  * this translation at all; each is declared in the Zig file that owns what
  * is done to it, and every Zig file shares that one declaration.
  *
  * Unlike `os/abi.h`, this one *does* include the Windows headers rather than
  * restating what it needs in Zig. `ev/stream.zig` took the other route and
  * declared `WSARecvFrom` and its kin by hand, because what it needed was four
  * calls and one structure. What the socket layer needs from Winsock is forty
  * integer constants whose values differ from the POSIX ones -- `SOL_SOCKET` is
 * `0xffff` against Linux's `1`, `AF_INET6` is 23 against 30 on macOS and 10 on
 * Linux -- and forty hand-copied magic numbers on a platform this project
 * builds but does not run is a worse bet than a translation the matrix
 * compiles. Measured on 2026-08-23, every declaration `net.zig` names
 * survives the translation for `x86_64-windows-gnu` except `WSAID_CONNECTEX`,
 * which is a brace initializer; that one is restated in `net/abi.zig`.
 *
 * `janet_features.h` comes first, as it must before any system header.
 */

#include "janet_features.h"

 /* Aro -- the `translate-c` front end in Zig 0.16 -- predefines `__unix__`,
  * `unix` and `__unix` for the mingw targets and clang does not, so a `@cImport`
  * of this file and a compilation of the same target disagree about the
  * predefine unless it is cleared. That produced a `JanetHandle` of `int`
  * rather than `void *` on `x86_64-windows-gnu`, from a platform chain that
  * tested Unix before Windows; `FOUND.md` records it.
  *
  * Every system header included below is read by `translate-c` and compiled by
  * clang, and this guard is what makes those two agree. The platform chains in
  * this file put their Windows arm first as well, which is belt to this
  * braces -- the two corrections are independent and both are cheap. */
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
 * Janet spelled `__gnu_hurd__` as `JANET_GNU_HURD`, one line above where it
 * used it. With no such header here the predefine is tested directly, which
 * is what that definition did. */
#if defined(SO_REUSEPORT) && !defined(__gnu_hurd__)
#define JANET_ZIG_REUSEPORT 1
#else
#define JANET_ZIG_REUSEPORT 0
#endif

/* Whether an `IP_MULTICAST_TTL` value is passed as `unsigned char` rather than
 * as `int`: the four BSD predefines and illumos, spelled out because the
 * enumeration has to stay in C. **Apple is deliberately not among them** --
 * it is its own predefine and this clause does not test it. */
#if defined(__FreeBSD__) || defined(__DragonFly__) || defined(__NetBSD__) \
    || defined(__OpenBSD__) || defined(__illumos__)
#define JANET_ZIG_MULTICAST_TTL_CHAR 1
#else
#define JANET_ZIG_MULTICAST_TTL_CHAR 0
#endif

#endif /* JANET_ZIG_NET_ABI_H */
