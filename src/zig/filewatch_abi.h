#ifndef JANET_ZIG_FILEWATCH_ABI_H
#define JANET_ZIG_FILEWATCH_ABI_H

/* The host headers `filewatch.c`'s three backends work through, prepared for
 * Zig's translate-c.
 *
 * This is the fourth translation in the tree, after `abi.zig`, `os_abi.h` and
 * `net_abi.h`, and it meets the rule those two record: a second translation is
 * right when nothing it declares crosses a subsystem boundary, and wrong when
 * it does. Nothing here does. A `struct inotify_event` is decoded inside one
 * event callback, a `struct kevent` is filled and passed to `kevent(2)` in one
 * function, and a `FILE_NOTIFY_INFORMATION` is read out of a buffer that
 * belongs to the watch it arrived for. The only things that outlive a call are
 * a `JanetStream *` and a `JanetChannel *`, and both come from `abi.zig`,
 * which every Zig object shares.
 *
 * Adding <sys/inotify.h> and <sys/event.h> to `abi.zig` would put a backend's
 * headers into the translation the whole tree shares, to serve one file.
 *
 * `features.h` comes first, as it must before any system header.
 */

#include "features.h"

/* Aro -- the translate-c front end in Zig 0.16 -- predefines `__unix__`,
 * `unix` and `__unix` for the mingw targets as well as `_WIN32`, and `janet.h`
 * tests its Unix chain before its Windows one. `os_abi.h`, `state_abi.h` and
 * `net_abi.h` carry the full reasoning and `FOUND.md` has the entry. Here the
 * correction decides which backend the translation selects, so it is as
 * load-bearing as it is there. */
#if defined(_WIN32) || defined(WIN32)
#undef __unix__
#undef unix
#undef __unix
#endif

/* `janet.h` is here for its *platform* names only -- `JANET_LINUX`,
 * `JANET_APPLE`, `JANET_BSD` and `JANET_WINDOWS` -- which the backend
 * selection at the bottom of this file tests exactly as `filewatch.c` does.
 * Nothing in `filewatch_abi.zig` reads a Janet type out of this translation;
 * those come from `abi.zig`, which is shared. */
#include <janet.h>

#include <errno.h>
#include <string.h>

#ifdef JANET_WINDOWS
#include <windows.h>
#else
#include <unistd.h>
#include <fcntl.h>
#include <sys/stat.h>
#endif

#ifdef JANET_LINUX
#include <sys/inotify.h>
#endif

#if defined(JANET_APPLE) || defined(JANET_BSD)
#include <sys/event.h>
#endif

/* Which backend this target compiles. The chain is `filewatch.c`'s exactly,
 * including its fall-through to the implementation whose every entry point
 * panics. Restated as an integer rather than read from the platform macros in
 * Zig because a `#define` with no value does not survive translation, which is
 * the reason `state_abi.h` restates five of `janet.h`'s flags and `net_abi.h`
 * three more. */
#define JANET_ZIG_WATCH_NONE 0
#define JANET_ZIG_WATCH_INOTIFY 1
#define JANET_ZIG_WATCH_WINDOWS 2
#define JANET_ZIG_WATCH_KQUEUE 3

#ifdef JANET_LINUX
#define JANET_ZIG_WATCH_BACKEND JANET_ZIG_WATCH_INOTIFY
#elif defined(JANET_WINDOWS)
#define JANET_ZIG_WATCH_BACKEND JANET_ZIG_WATCH_WINDOWS
#elif defined(JANET_APPLE) || defined(JANET_BSD)
#define JANET_ZIG_WATCH_BACKEND JANET_ZIG_WATCH_KQUEUE
#else
#define JANET_ZIG_WATCH_BACKEND JANET_ZIG_WATCH_NONE
#endif

#endif /* JANET_ZIG_FILEWATCH_ABI_H */
