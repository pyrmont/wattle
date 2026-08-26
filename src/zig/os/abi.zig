//! The single translation of the host headers `os.c` worked through.
//!
//! `os/abi.h` carries the reasoning, including why this is a second
//! translation rather than four lines added to `abi.zig`, and what is
//! deliberately absent from it. The four files of the `-Dos-surface` object
//! share this module, so a `struct tm` filled by one is the same Zig type as a
//! `struct tm` read by another.

pub const h = @cImport({
    @cInclude("os/abi.h");
});

/// `PATH_MAX`, or `os.c`'s substitute where the platform omits it.
pub const path_max: usize = h.JANET_ZIG_PATH_MAX;

/// Whether `posix_spawn_file_actions_addchdir` is available, and under which
/// of its two spellings. C works this out by enumerating systems; see
/// `os/abi.h`.
pub const spawn_chdir = h.JANET_ZIG_SPAWN_CHDIR != 0;
pub const spawn_chdir_np = h.JANET_ZIG_SPAWN_CHDIR_NP != 0;

const std = @import("std");
const builtin = @import("builtin");

/// The process environment vector.
///
/// Three spellings, and the reason they are here rather than in one of the
/// four subsystem files is that two of them need it: `os/environ` reads it and
/// `os/posix-exec` assigns to it. macOS has no `environ` symbol a shared
/// library may reference and supplies `_NSGetEnviron()` instead, which is what
/// `os.c` spells as a macro; mingw spells `_environ` as a macro over
/// `__p__environ()` and exports only the accessor; everything else has the
/// POSIX global.
const EnvironVector = ?[*]?[*:0]u8;

extern fn _NSGetEnviron() callconv(.c) *EnvironVector;
extern fn __p__environ() callconv(.c) *EnvironVector;
extern var environ: EnvironVector;

inline fn environPtr() *EnvironVector {
    return switch (builtin.os.tag) {
        .macos, .ios, .tvos, .watchos, .visionos => _NSGetEnviron(),
        // mingw's `_environ` is a macro over `__p__environ()`, and only the
        // accessor is a symbol its import library exports.
        .windows => __p__environ(),
        else => &environ,
    };
}

pub inline fn getEnviron() EnvironVector {
    return environPtr().*;
}

pub inline fn setEnviron(value: EnvironVector) void {
    environPtr().* = value;
}

/// `janet_lock_environ` and `janet_unlock_environ`.
///
/// Both are empty in every build this tree can produce. `os.c` guards the real
/// bodies -- a `pthread_mutex_t` or a `CRITICAL_SECTION` -- with
/// `JANET_THREADS`, and `FOUND.md` records that `JANET_THREADS` is defined
/// nowhere in the tree. The guarded arms are recorded here rather than
/// written, on Part 8's rule: Zig does not analyse a comptime-false branch, so
/// carrying them would produce something even less checked than the C they
/// replaced.
///
/// They are kept as named no-ops rather than deleted because the *places* they
/// are called from are the contract -- `os/getenv` holds the lock across the
/// copy of a borrowed `getenv` result, and `os/execute` holds it across the
/// spawn -- and those call sites are what a future threaded build would need.
pub inline fn lockEnviron() void {}
pub inline fn unlockEnviron() void {}
