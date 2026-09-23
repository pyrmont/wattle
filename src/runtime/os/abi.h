#ifndef WATTLE_OS_ABI_H
#define WATTLE_OS_ABI_H

 /* The host structures the `os/` surface works through, prepared for Zig's
  * `translate-c`.
  *
  * `struct tm`, `posix_spawn_file_actions_t` and their kin have layouts only
  * the platform header knows. They stay libc's, and Zig reaches them here:
  * "no C in the tree" and "no libc" are different claims and only the first is
  * a goal.
  *
  * This is a translation of its own and it is deliberate. Nothing declared here
  * crosses a subsystem boundary: a `struct tm` lives for the length of one
  * nfunction, a `posix_spawn_file_actions_t` for the length of one spawn. One
  * header, one Zig type: this file is included once, by `os/abi.zig`, and the
  * files of the `os/` subtree share it.
 *
 * `wattle_features.h` comes first, as it must before any system header: it is what
 * sets `_POSIX_C_SOURCE`, and without it `localtime_r`, `gmtime_r` and
 * `sigaction` are not declared.
 *
 * What is *not* here is as much of the point. `struct stat` and `struct
 * timespec` are absent because translate-c cannot give them to us on every
 * target -- see `os/fs/host_stat.zig` for the measurement and the answer.
 * Scalar host calls are not here either; a file that needs `chmod` or
 * `isatty` declares it directly, because a one-line `extern fn` has no layout
 * to get wrong and does not grow the translation. */

#include "wattle_features.h"

 /* Aro -- the `translate-c` front end in Zig 0.16 -- predefines `__unix__`,
  * `unix` and `__unix` for the mingw targets and clang does not, so a `@cImport`
  * of this file and a compilation of the same target disagree about the
  * predefine unless it is cleared. That produced a `JanetHandle` of `int`
  * rather than `void *` on `x86_64-windows-gnu`, from a platform chain that
  * tested Unix before Windows.
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
#include <fcntl.h>
#include <limits.h>
#include <locale.h>
/* wasi-libc's `signal.h` is an `#error` unless `_WASI_EMULATED_SIGNAL` is
 * defined. A WASI build has no process functions and no event loop, and those
 * are the only readers of it. */
#if !defined(__wasi__)
#include <signal.h>
#endif
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

/* Zig's `std.c` types a WASI `readdir` result as `void`, so `os/fs.zig` reads
 * the entry through this translation's `struct dirent` there. Elsewhere
 * `std.c.readdir` carries the platform's symbol name and layout.
 *
 * wasi-libc declares `d_name` as a flexible array member, which `translate-c`
 * drops, and `sizeof(struct dirent)` is not where it begins. The accessor is
 * what keeps that offset C's to work out rather than Zig's to restate. */
#if defined(__wasi__)
#include <dirent.h>

static inline const char *wattle_dirent_name(const struct dirent *entry) {
    return entry->d_name;
}
#endif

/* `spawn.h` puts its Darwin extensions behind `_DARWIN_C_SOURCE`, which
 * `wattle_features.h` defines, and that block includes
 * `mach/exception_types.h`. The chain reaches `mach/message.h`, whose message
 * descriptor structs hold bitfields; `translate-c` demotes each to an opaque
 * type, and the header's own `_Static_assert` on their sizes, live under
 * `__arm64__`, then asks `@sizeOf` of an opaque type. That assertion is in
 * Zig's bundled Darwin headers, which a build naming a target reads in place
 * of the host SDK, and the SDK's copy of the header omits it. Clearing the
 * macro for this one include stops `spawn.h` at its POSIX declarations. This
 * translation reads no Darwin spawn extension: `posix_spawn_file_actions_t`
 * and the `posix_spawn` family are declared above the block. */
#if defined(__APPLE__)
#undef _DARWIN_C_SOURCE
#include <spawn.h>
#define _DARWIN_C_SOURCE
#else
#include <spawn.h>
#endif

#include <pthread.h>
#endif

/* `PATH_MAX` is not required to exist, and `os.c` supplies 8192 for the one
 * platform in this project's reach that omits it. Restated here so that a Zig
 * `@hasDecl` does not have to repeat the condition. */
#ifndef PATH_MAX
#define WATTLE_PATH_MAX 8192
#else
#define WATTLE_PATH_MAX PATH_MAX
#endif

/* Whether `posix_spawn_file_actions_addchdir_np` is available. `os.c` works
 * this out by enumerating systems, because the extension follows no standard;
 * the enumeration is C's and stays C's, and Zig reads the answer. The two
 * spellings differ only in the `_np` suffix. */
#if defined(_WIN32)
#define WATTLE_SPAWN_CHDIR 0
#define WATTLE_SPAWN_CHDIR_NP 0
#elif defined(WATTLE_SPAWN_NO_CHDIR)
#define WATTLE_SPAWN_CHDIR 0
#define WATTLE_SPAWN_CHDIR_NP 0
#elif defined(__GLIBC__)
#define WATTLE_SPAWN_CHDIR 1
#define WATTLE_SPAWN_CHDIR_NP 1
#elif defined(__APPLE__)
#include <AvailabilityMacros.h>
#if defined(MAC_OS_X_VERSION_10_15) && (MAC_OS_X_VERSION_MIN_REQUIRED >= MAC_OS_X_VERSION_10_15)
#define WATTLE_SPAWN_CHDIR 1
#define WATTLE_SPAWN_CHDIR_NP 1
#else
#define WATTLE_SPAWN_CHDIR 0
#define WATTLE_SPAWN_CHDIR_NP 0
#endif
#elif defined(__FreeBSD__)
#define WATTLE_SPAWN_CHDIR 1
#define WATTLE_SPAWN_CHDIR_NP 1
#else
#define WATTLE_SPAWN_CHDIR 0
#define WATTLE_SPAWN_CHDIR_NP 0
#endif

#endif /* WATTLE_OS_ABI_H */
