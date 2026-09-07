//! The single translation of the host headers `os.c` worked through.
//!
//! `os/abi.h` has the reasoning, including why this is a second translation
//! rather than four lines added to `abi.zig`, and what is deliberately absent
//! from it. Every file of the `os/` subsystem shares this module, so a
//! `struct tm` filled by one is the same Zig type as a `struct tm` read by
//! another.
//!
//! A host declaration belongs here rather than in `cabi.zig` when one of its
//! parameters is `h.`-something: `struct tm`, `time_t`, `sigset_t`,
//! `posix_spawn_file_actions_t`, `SECURITY_ATTRIBUTES`. Those types are this
//! translation's, and a host header stays inside the subsystem that translates
//! it, so the declaration follows the type rather than the type following the
//! declaration. Everything else `os/` calls is plain libc and is in
//! `cabi.zig`.

// ==========================================================================
// Standard library imports
// ==========================================================================

const builtin = @import("builtin");

// ==========================================================================
// Project imports
// ==========================================================================

const host = @import("host");

/// The translation itself. Every `h.`-qualified type below is one of its
/// declarations.
pub const h = @cImport({
    @cInclude("os/abi.h");
});

// ==========================================================================
// Constants
// ==========================================================================

/// The POSIX global, which is the arm `environPtr` takes off macOS and
/// Windows.
extern var environ: EnvironVector;

/// `PATH_MAX`, or `os.c`'s substitute where the platform omits it.
pub const path_max: usize = h.JANET_ZIG_PATH_MAX;

/// Whether `posix_spawn_file_actions_addchdir` is available, and under which
/// of its two spellings. `os/abi.h` is where the platforms are enumerated.
pub const spawn_chdir = h.JANET_ZIG_SPAWN_CHDIR != 0;
pub const spawn_chdir_np = h.JANET_ZIG_SPAWN_CHDIR_NP != 0;

// ==========================================================================
// Aliased types
// ==========================================================================

/// `mode_t`, which POSIX gets from this translation and Windows spells as an
/// `unsigned short`. `os/fs/stat.zig` re-exports it as `jmode_t`.
pub const jmode_t = if (builtin.os.tag == .windows) c_ushort else h.mode_t;

// ==========================================================================
// Types
// ==========================================================================

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

// ==========================================================================
// Public functions
// ==========================================================================

/// The two Windows APIs whose signatures name a type from this translation.
///
/// `callconv(.winapi)`, not `.c`. `os/process.zig` declared both `.c`, and
/// `ev/stream.zig` declared its own `CreatePipe` `extern "kernel32"` with
/// `.winapi` three files away. The two are the same convention on x86-64
/// Windows only by accident of the target; `.winapi` is what the header says
/// and what the other declaration already used.
pub extern "kernel32" fn CreatePipe(
    read: *host.Handle,
    write: *host.Handle,
    attrs: *h.SECURITY_ATTRIBUTES,
    size: u32,
) callconv(.winapi) c_int;

pub extern "kernel32" fn CreateProcessA(
    application: ?[*:0]const u8,
    command_line: ?[*]u8,
    proc_attrs: ?*h.SECURITY_ATTRIBUTES,
    thread_attrs: ?*h.SECURITY_ATTRIBUTES,
    inherit: c_int,
    flags: u32,
    environment: ?*anyopaque,
    current_directory: ?[*:0]const u8,
    startup: *h.STARTUPINFOA,
    info: *h.PROCESS_INFORMATION,
) callconv(.winapi) c_int;

/// The Microsoft reentrant pair. `localtime_s` and `gmtime_s` are declared in
/// mingw's `<time.h>` but are not symbols its import library exports: the
/// header maps them onto the CRT's `_localtime64_s` and `_gmtime64_s`, and a C
/// build links against those. Calling the declared names compiles and fails to
/// link, which only a cross-compile catches.
///
/// The `64` in those names is the width of the `time_t` they take, so a mingw
/// configured with `_USE_32BIT_TIME_T` would need the other pair. This project
/// cross-compiles only `x86_64-windows-gnu`, and a narrow `time_t` is a
/// compile error rather than a silent mismatch.
pub extern fn _gmtime64_s(out: *h.struct_tm, t: *const h.time_t) callconv(.c) c_int;

pub extern fn _localtime64_s(out: *h.struct_tm, t: *const h.time_t) callconv(.c) c_int;

pub extern fn _mkgmtime(t: *h.struct_tm) callconv(.c) h.time_t;

pub extern fn chmod(path: [*:0]const u8, mode: jmode_t) callconv(.c) c_int;

/// The environment vector as it stands.
pub inline fn getEnviron() EnvironVector {
    return environPtr().*;
}

pub extern fn gmtime_r(t: *const h.time_t, out: *h.struct_tm) callconv(.c) ?*h.struct_tm;

pub extern fn localtime_r(t: *const h.time_t, out: *h.struct_tm) callconv(.c) ?*h.struct_tm;

/// The environment lock and unlock.
///
/// Both are empty in every build this tree can produce. Janet guards the real
/// bodies, a `pthread_mutex_t` or a `CRITICAL_SECTION`, with `JANET_THREADS`,
/// which no build in this tree defines. The guarded arms are recorded here
/// rather than written: Zig does not analyse a comptime-false branch, so
/// writing them out would produce something nothing checks.
///
/// They are kept as named no-ops rather than deleted because the places they
/// are called from are what a future threaded build would need: `os/getenv`
/// takes the lock across the copy of a borrowed `getenv` result, and
/// `os/execute` takes it across the spawn.
pub inline fn lockEnviron() void {}

pub extern fn mktime(t: *h.struct_tm) callconv(.c) h.time_t;

pub extern fn posix_spawn(
    pid: *h.pid_t,
    path: [*:0]const u8,
    actions: ?*const h.posix_spawn_file_actions_t,
    attrp: ?*const anyopaque,
    argv: [*:null]const ?[*:0]const u8,
    envp: ?[*]?[*:0]u8,
) callconv(.c) c_int;

pub extern fn posix_spawn_file_actions_addchdir(actions: *h.posix_spawn_file_actions_t, path: [*:0]const u8) callconv(.c) c_int;

pub extern fn posix_spawn_file_actions_addchdir_np(actions: *h.posix_spawn_file_actions_t, path: [*:0]const u8) callconv(.c) c_int;

pub extern fn posix_spawn_file_actions_addclose(actions: *h.posix_spawn_file_actions_t, fd: c_int) callconv(.c) c_int;

pub extern fn posix_spawn_file_actions_adddup2(actions: *h.posix_spawn_file_actions_t, fd: c_int, newfd: c_int) callconv(.c) c_int;

pub extern fn posix_spawn_file_actions_destroy(actions: *h.posix_spawn_file_actions_t) callconv(.c) c_int;

pub extern fn posix_spawn_file_actions_init(actions: *h.posix_spawn_file_actions_t) callconv(.c) c_int;

pub extern fn posix_spawnp(
    pid: *h.pid_t,
    file: [*:0]const u8,
    actions: ?*const h.posix_spawn_file_actions_t,
    attrp: ?*const anyopaque,
    argv: [*:null]const ?[*:0]const u8,
    envp: ?[*]?[*:0]u8,
) callconv(.c) c_int;

/// Replaces the environment vector, which `os/posix-exec` does.
pub inline fn setEnviron(value: EnvironVector) void {
    environPtr().* = value;
}

pub extern fn sigaction(sig: c_int, act: *const h.struct_sigaction, old: ?*h.struct_sigaction) callconv(.c) c_int;

pub extern fn sigaddset(set: *h.sigset_t, sig: c_int) callconv(.c) c_int;

pub extern fn sigemptyset(set: *h.sigset_t) callconv(.c) c_int;

pub extern fn sigprocmask(how: c_int, set: *const h.sigset_t, old: ?*h.sigset_t) callconv(.c) c_int;

pub extern fn strftime(buf: [*]u8, size: usize, fmt: [*:0]const u8, t: *const h.struct_tm) callconv(.c) usize;

pub extern fn time(t: ?*h.time_t) callconv(.c) h.time_t;

pub extern fn timegm(t: *h.struct_tm) callconv(.c) h.time_t;

pub extern fn umask(mask: jmode_t) callconv(.c) jmode_t;

/// The unlock, which is `lockEnviron`'s no-op partner.
pub inline fn unlockEnviron() void {}

// ==========================================================================
// Private functions
// ==========================================================================

/// The macOS accessor, which is what `os.c` spells as a macro.
extern fn _NSGetEnviron() callconv(.c) *EnvironVector;

/// The mingw accessor. Its `_environ` is a macro over this, and only this is a
/// symbol the import library exports.
extern fn __p__environ() callconv(.c) *EnvironVector;

/// The address of the environment vector, whichever of the three spellings
/// this platform has.
inline fn environPtr() *EnvironVector {
    return switch (builtin.os.tag) {
        .macos, .ios, .tvos, .watchos, .visionos => _NSGetEnviron(),
        // mingw's `_environ` is a macro over `__p__environ()`, and only the
        // accessor is a symbol its import library exports.
        .windows => __p__environ(),
        else => &environ,
    };
}
