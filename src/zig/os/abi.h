#ifndef JANET_ZIG_OS_ABI_H
#define JANET_ZIG_OS_ABI_H

/* The host structures `os.c` works through, prepared for Zig's translate-c.
 *
 * Phase 10's decision 4 overturned a judgment recorded under "Current state"
 * in `PLAN.md`: process control and the calendar were parked as permanently
 * C, on the grounds that `struct tm`, `posix_spawn_file_actions_t` and their
 * kin have layouts only the platform header knows. The decision keeps that
 * reasoning for the *structures* and drops it for the *language* -- they stay
 * libc's, and Zig reaches them here. "No C in the tree" and "no libc" are
 * different claims and only the first is a goal.
 *
 * This is a translation of its own and it is deliberate. Nothing declared here
 * crosses a subsystem boundary: a `struct tm` lives for the length of one
 * cfunction, a `posix_spawn_file_actions_t` for the length of one spawn. Until
 * Phase 12 increment 5f the alternative was adding these headers to
 * `abi.zig`'s shared `@cImport`, which would have put `<windows.h>` into the
 * translation every Zig object in the tree shares, to serve four files. That
 * translation is retired with `janet.h` and no Janet type comes through a
 * `@cImport` any more; the rule survives its subject, because what it was
 * protecting was one header having one Zig type, and it is still met -- this
 * header is included once, by `os/abi.zig`, and the files of the `-Dos-surface`
 * object share it.
 *
 * `janet_features.h` comes first, as it must before any system header: it is what
 * sets `_POSIX_C_SOURCE`, and without it `localtime_r`, `gmtime_r` and
 * `sigaction` are not declared.
 *
 * What is *not* here is as much of the point. `struct stat` and `struct
 * timespec` are absent because translate-c cannot give them to us on every
 * target -- see `os_files.zig` for the measurement and what `os.c` keeps as a
 * result. Scalar host calls are not here either; a file that needs `chmod` or
 * `isatty` declares it directly, because a one-line `extern fn` has no layout
 * to get wrong and does not grow the translation. */

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
#include <fcntl.h>
#include <limits.h>
#include <locale.h>
#include <signal.h>
#include <stdio.h>
#include <time.h>

#ifdef _WIN32
#include <windows.h>
#include <direct.h>
#include <io.h>
#include <process.h>
#include <sys/utime.h>
#else
#include <unistd.h>
#include <spawn.h>
#include <pthread.h>
#endif

/* `PATH_MAX` is not required to exist, and `os.c` supplies 8192 for the one
 * platform in this project's reach that omits it. Restated here so that a Zig
 * `@hasDecl` does not have to repeat the condition. */
#ifndef PATH_MAX
#define JANET_ZIG_PATH_MAX 8192
#else
#define JANET_ZIG_PATH_MAX PATH_MAX
#endif

/* Whether `posix_spawn_file_actions_addchdir_np` is available. `os.c` works
 * this out by enumerating systems, because the extension follows no standard;
 * the enumeration is C's and stays C's, and Zig reads the answer. The two
 * spellings differ only in the `_np` suffix. */
#if defined(_WIN32)
#define JANET_ZIG_SPAWN_CHDIR 0
#define JANET_ZIG_SPAWN_CHDIR_NP 0
#elif defined(JANET_SPAWN_NO_CHDIR)
#define JANET_ZIG_SPAWN_CHDIR 0
#define JANET_ZIG_SPAWN_CHDIR_NP 0
#elif defined(__GLIBC__)
#define JANET_ZIG_SPAWN_CHDIR 1
#define JANET_ZIG_SPAWN_CHDIR_NP 1
#elif defined(__APPLE__)
#include <AvailabilityMacros.h>
#if defined(MAC_OS_X_VERSION_10_15) && (MAC_OS_X_VERSION_MIN_REQUIRED >= MAC_OS_X_VERSION_10_15)
#define JANET_ZIG_SPAWN_CHDIR 1
#define JANET_ZIG_SPAWN_CHDIR_NP 1
#else
#define JANET_ZIG_SPAWN_CHDIR 0
#define JANET_ZIG_SPAWN_CHDIR_NP 0
#endif
#elif defined(__FreeBSD__)
#define JANET_ZIG_SPAWN_CHDIR 1
#define JANET_ZIG_SPAWN_CHDIR_NP 1
#else
#define JANET_ZIG_SPAWN_CHDIR 0
#define JANET_ZIG_SPAWN_CHDIR_NP 0
#endif

#endif /* JANET_ZIG_OS_ABI_H */
