#ifndef WATTLE_FILEWATCH_ABI_H
#define WATTLE_FILEWATCH_ABI_H

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
 * a `Stream *` and a `Channel *`, and those are `ev/stream.zig`'s and
 * `ev/channel.zig`'s, which are Zig and which every file shares.
 *
 * `wattle_features.h` comes first, as it must before any system header.
 */

#include "wattle_features.h"

 /* The platform chain, tested against the predefines directly, with the
  * Windows arm first. */

#include <errno.h>
#include <string.h>

#if defined(_WIN32) || defined(WIN32)
#include <windows.h>
#else
#include <unistd.h>
#include <fcntl.h>
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
 * Windows leads, where `filewatch.c` led with Linux, so that the chain gives
 * the same answer for a mingw target whether or not a front end predefines
 * the Unix names there, as Aro did in Zig 0.16. The three arms are mutually
 * exclusive on every real target, so the reordering changes nothing else. */
#define WATTLE_WATCH_NONE 0
#define WATTLE_WATCH_INOTIFY 1
#define WATTLE_WATCH_WINDOWS 2
#define WATTLE_WATCH_KQUEUE 3

#if defined(_WIN32) || defined(WIN32)
#define WATTLE_WATCH_BACKEND WATTLE_WATCH_WINDOWS
#elif defined(__linux__)
#define WATTLE_WATCH_BACKEND WATTLE_WATCH_INOTIFY
#elif (defined(__APPLE__) && defined(__MACH__)) \
    || defined(__FreeBSD__) || defined(__DragonFly__) \
    || defined(__NetBSD__) || defined(__OpenBSD__)
#define WATTLE_WATCH_BACKEND WATTLE_WATCH_KQUEUE
#else
#define WATTLE_WATCH_BACKEND WATTLE_WATCH_NONE
#endif

#endif /* WATTLE_FILEWATCH_ABI_H */
