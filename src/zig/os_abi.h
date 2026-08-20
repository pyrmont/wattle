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
 * This is a second translation and it is deliberate. `abi.zig` translates
 * Janet's own headers and is shared by every subsystem so that a `JanetFiber *`
 * produced by one is the same Zig type as a `JanetFiber *` consumed by
 * another. Nothing declared here crosses a subsystem boundary: a `struct tm`
 * lives for the length of one cfunction, a `posix_spawn_file_actions_t` for
 * the length of one spawn. Adding these headers to `abi.zig` instead would put
 * `<windows.h>` into the translation every Zig object in the tree shares, to
 * serve four files. The single-translation rule is about one header having one
 * Zig type, and it is met: this header is included once, by `os_abi.zig`, and
 * the four files of the `-Dos-surface` object share that module.
 *
 * `features.h` comes first, as it must before any system header: it is what
 * sets `_POSIX_C_SOURCE`, and without it `localtime_r`, `gmtime_r` and
 * `sigaction` are not declared.
 *
 * What is *not* here is as much of the point. `struct stat` and `struct
 * timespec` are absent because translate-c cannot give them to us on every
 * target -- see `os_files.zig` for the measurement and what `os.c` keeps as a
 * result. Scalar host calls are not here either; a file that needs `chmod` or
 * `isatty` declares it directly, because a one-line `extern fn` has no layout
 * to get wrong and does not grow the translation. */

#include "features.h"

/* Aro -- the translate-c front end in Zig 0.16 -- predefines `__unix__`,
 * `unix` and `__unix` for the mingw targets as well as `_WIN32`, and
 * `janet.h` tests its Unix chain *before* its Windows one. So the translation
 * of `janet.h` for `x86_64-windows-gnu` defines `JANET_POSIX` where the
 * compilation of the same header for the same target defines `JANET_WINDOWS`,
 * and every type that varies by platform -- `JanetHandle` above all, which is
 * `void *` on Windows and `int` elsewhere -- comes out describing the wrong
 * operating system. Nothing detected it until a Zig subsystem first needed
 * one of those types, in Phase 10 Part 12.
 *
 * The correction belongs here rather than in `janet.h`: it is a fact about
 * the tool, the C build is already right, and this file exists to make
 * exactly this kind of translation-only adjustment. `FOUND.md` records it.
 */
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
