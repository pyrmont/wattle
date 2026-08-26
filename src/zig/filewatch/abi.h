#ifndef JANET_ZIG_FILEWATCH_ABI_H
#define JANET_ZIG_FILEWATCH_ABI_H

/* The host headers `filewatch.c`'s three backends work through, prepared for
 * Zig's translate-c.
 *
 * The last of three host translations, beside `os/abi.h` and `net/abi.h`, and
 * it meets the rule those two record: a second translation is right when
 * nothing it declares crosses a subsystem boundary, and wrong when it does.
 * Nothing here does. A `struct inotify_event` is decoded inside one event
 * callback, a `struct kevent` is filled and passed to `kevent(2)` in one
 * function, and a `FILE_NOTIFY_INFORMATION` is read out of a buffer that
 * belongs to the watch it arrived for. The only things that outlive a call are
 * a `JanetStream *` and a `JanetChannel *`, and those are `types.zig`'s, which
 * is Zig and which every file shares.
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

/* The platform chain, tested against the predefines directly.
 *
 * `janet.h` was included here for its *platform* names alone -- `JANET_LINUX`,
 * `JANET_APPLE`, `JANET_BSD`, `JANET_WINDOWS` -- each of which it defined one
 * line away from the predefine it tested. Phase 12 increment 5f retired the
 * header, so the tests below are `janet.h`'s own, spelled out, with the
 * Windows arm first. */

#include <errno.h>
#include <string.h>

#if defined(_WIN32) || defined(WIN32)
#include <windows.h>
#else
#include <unistd.h>
#include <fcntl.h>
#include <sys/stat.h>
#endif

#ifdef __linux__
#include <sys/inotify.h>
#endif

#if (defined(__APPLE__) && defined(__MACH__)) \
    || defined(__FreeBSD__) || defined(__DragonFly__) \
    || defined(__NetBSD__) || defined(__OpenBSD__)
#include <sys/event.h>
#endif

/* Which backend this target compiles. The chain is `filewatch.c`'s exactly,
 * including its fall-through to the implementation whose every entry point
 * panics. Restated as an integer rather than read from the platform macros in
 * Zig because a `#define` with no value does not survive translation, which is
 * the reason `net/abi.h` restates three flags of its own.
 *
 * Windows leads, where `filewatch.c` led with Linux, for the reason the
 * include block above gives: this chain has to answer the same on a mingw
 * translation as on a mingw compilation, and Aro predefines the Unix names
 * there too. The three arms are mutually exclusive on every real target, so
 * the reordering changes nothing else. */
#define JANET_ZIG_WATCH_NONE 0
#define JANET_ZIG_WATCH_INOTIFY 1
#define JANET_ZIG_WATCH_WINDOWS 2
#define JANET_ZIG_WATCH_KQUEUE 3

#if defined(_WIN32) || defined(WIN32)
#define JANET_ZIG_WATCH_BACKEND JANET_ZIG_WATCH_WINDOWS
#elif defined(__linux__)
#define JANET_ZIG_WATCH_BACKEND JANET_ZIG_WATCH_INOTIFY
#elif (defined(__APPLE__) && defined(__MACH__)) \
    || defined(__FreeBSD__) || defined(__DragonFly__) \
    || defined(__NetBSD__) || defined(__OpenBSD__)
#define JANET_ZIG_WATCH_BACKEND JANET_ZIG_WATCH_KQUEUE
#else
#define JANET_ZIG_WATCH_BACKEND JANET_ZIG_WATCH_NONE
#endif

#endif /* JANET_ZIG_FILEWATCH_ABI_H */
