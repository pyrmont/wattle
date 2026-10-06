//! The host declarations the `os/` subsystem works through.
//!
//! `os/` reaches them as `sys`, a namespace of C names. Each comes from Zig's
//! standard library where the standard library declares it with the
//! platform's value or layout, and is written here where it does not: the
//! `LC_*` categories outside glibc's numbering, `time_t` on 32-bit musl,
//! `struct tm`, the spawn file actions, the path limits, and the Windows file,
//! process and CRT declarations, none of which Zig 0.17's `std.os.windows`
//! has. Every file of the `os/` subsystem shares this module, so a `struct tm`
//! filled by one is the same Zig type as a `struct tm` read by another.
//!
//! A host function belongs here rather than in `cabi.zig` when one of its
//! parameters is a type from `sys`: `struct tm`, `time_t`, `sigset_t`,
//! `posix_spawn_file_actions_t`, `SECURITY_ATTRIBUTES`. Those types stay
//! inside this subsystem, so the declaration follows the type rather than the
//! type following the declaration. Everything else `os/` calls is plain libc
//! and is in `cabi.zig`.

// ==========================================================================
// Standard library imports
// ==========================================================================

const std = @import("std");
const builtin = @import("builtin");

// ==========================================================================
// Project imports
// ==========================================================================

const host = @import("host");

// ==========================================================================
// Constants
// ==========================================================================

/// The POSIX global, which is the arm `environPtr` takes off macOS and
/// Windows.
extern var environ: EnvironVector;

/// `PATH_MAX`: 4096 on Linux and wasi, 1024 on macOS and FreeBSD, and
/// `MAX_PATH`, 260, on Windows.
pub const path_max: usize = if (windows) 260 else if (darwin or freebsd) 1024 else 4096;

/// Whether this target is macOS.
const darwin = builtin.target.os.tag.isDarwin();

/// Whether this target is FreeBSD.
const freebsd = builtin.target.os.tag == .freebsd;

/// Whether the libc numbers the `LC_*` categories as glibc does: glibc, musl
/// and wasi-libc.
const glibc_lc = builtin.target.os.tag == .linux or wasi;

/// Whether this target is wasi.
const wasi = builtin.target.os.tag == .wasi;

/// Whether this target is Windows.
const windows = builtin.target.os.tag == .windows;

/// Whether `posix_spawn_file_actions_addchdir` is available, and under which
/// of its two spellings. glibc, macOS from 10.15 and FreeBSD have the `_np`
/// spelling; musl, mingw and wasi-libc have neither.
pub const spawn_chdir = (builtin.target.os.tag == .linux and builtin.target.abi.isGnu()) or darwin or freebsd;
pub const spawn_chdir_np = spawn_chdir;

// ==========================================================================
// Aliased types
// ==========================================================================

/// `mode_t`, which Windows spells as an `unsigned short`.
/// `os/fs/stat.zig` re-exports it as `jmode_t`.
pub const jmode_t = sys.mode_t;

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

/// The host declarations written in Zig, under their C names.
pub const sys = struct {
    // Locale categories. `std.c.LC` has glibc's numbering on every OS, which
    // musl and wasi-libc share; macOS, FreeBSD and mingw number them from
    // `LC_ALL` at 0.

    pub const LC_ALL = if (glibc_lc) @backingInt(std.c.LC.ALL) else 0;
    pub const LC_COLLATE = if (glibc_lc) @backingInt(std.c.LC.COLLATE) else 1;
    pub const LC_CTYPE = if (glibc_lc) @backingInt(std.c.LC.CTYPE) else 2;
    pub const LC_MONETARY = if (glibc_lc) @backingInt(std.c.LC.MONETARY) else 3;
    pub const LC_NUMERIC = if (glibc_lc) @backingInt(std.c.LC.NUMERIC) else 4;
    pub const LC_TIME = if (glibc_lc) @backingInt(std.c.LC.TIME) else 5;

    /// `mode_t`: `std.c.mode_t` on POSIX and an `unsigned short` on Windows.
    pub const mode_t = if (windows) c_ushort else std.c.mode_t;

    /// `time_t`. 64 bits on every target the runtime builds for: musl's is
    /// `int64_t` on 32-bit targets too, where `std.c.time_t` is the kernel's
    /// 32-bit type, and mingw's is `__time64_t`.
    pub const time_t = if (windows or wasi or builtin.target.abi.isMusl()) i64 else c_long;

    /// `struct tm`. The nine `int` fields are common to every platform. POSIX
    /// adds `tm_gmtoff` and `tm_zone`, whose `long` and pointer widths make it
    /// 56 bytes on a 64-bit target and 44 on a 32-bit one, and wasi-libc adds
    /// a nanoseconds field after them. mingw has the nine alone.
    pub const struct_tm = if (windows) extern struct {
        tm_sec: c_int,
        tm_min: c_int,
        tm_hour: c_int,
        tm_mday: c_int,
        tm_mon: c_int,
        tm_year: c_int,
        tm_wday: c_int,
        tm_yday: c_int,
        tm_isdst: c_int,
    } else if (wasi) extern struct {
        tm_sec: c_int,
        tm_min: c_int,
        tm_hour: c_int,
        tm_mday: c_int,
        tm_mon: c_int,
        tm_year: c_int,
        tm_wday: c_int,
        tm_yday: c_int,
        tm_isdst: c_int,
        tm_gmtoff: c_long,
        tm_zone: ?[*:0]const u8,
        tm_nsec: c_int,
    } else extern struct {
        tm_sec: c_int,
        tm_min: c_int,
        tm_hour: c_int,
        tm_mday: c_int,
        tm_mon: c_int,
        tm_year: c_int,
        tm_wday: c_int,
        tm_yday: c_int,
        tm_isdst: c_int,
        tm_gmtoff: c_long,
        tm_zone: ?[*:0]const u8,
    };

    // Errors, descriptor flags and signals.

    pub const EEXIST = @backingInt(std.c.E.EXIST);
    pub const ENOENT = @backingInt(std.c.E.NOENT);
    pub const F_SETFD = std.c.F.SETFD;
    pub const FD_CLOEXEC = std.c.FD_CLOEXEC;
    pub const SA_RESTART = std.c.SA.RESTART;
    pub const SIG_BLOCK = std.c.SIG.BLOCK;
    pub const SIG_UNBLOCK = std.c.SIG.UNBLOCK;
    pub const SIGKILL = @backingInt(std.c.SIG.KILL);
    pub const sigset_t = std.c.sigset_t;
    pub const struct_sigaction = std.c.Sigaction;

    /// The number of the signal named `name`, such as `"SIGHUP"`, or null where
    /// the platform has no such signal. wasi-libc has no signals.
    pub fn signalNumber(comptime name: []const u8) ?c_int {
        if (wasi) return null;
        // Linux's `SIGPOLL` is its `SIGIO`, which is the name `std` gives it.
        const short = if (builtin.target.os.tag == .linux and std.mem.eql(u8, name, "SIGPOLL")) "IO" else name["SIG".len..];
        if (!@hasField(std.c.SIG, short)) return null;
        return @intCast(@backingInt(@field(std.c.SIG, short)));
    }

    /// `pid_t`, and mingw's 64-bit `_pid_t` on Windows.
    pub const pid_t = if (windows) i64 else std.c.pid_t;

    // `open` flags, as the `int` the call takes. `std.c.O` is a packed struct
    // of the platform's bits. glibc and musl define `O_SYNC` as `__O_SYNC`
    // with `O_DSYNC`, wasi-libc defines `O_CLOEXEC` and `O_NOCTTY` as 0, and
    // `std` spells wasi's access mode as a read bit and a write bit. Windows
    // opens a file with `CreateFileA` and has none of them.

    pub const O_APPEND = openFlags(.{ .APPEND = true });
    pub const O_CLOEXEC = if (wasi) 0 else openFlags(.{ .CLOEXEC = true });
    pub const O_CREAT = openFlags(.{ .CREAT = true });
    pub const O_EXCL = openFlags(.{ .EXCL = true });
    pub const O_NOCTTY = if (wasi) 0 else openFlags(.{ .NOCTTY = true });
    pub const O_NONBLOCK = openFlags(.{ .NONBLOCK = true });
    pub const O_RDONLY = openFlags(if (wasi) .{ .read = true } else .{ .ACCMODE = .RDONLY });
    pub const O_RDWR = openFlags(if (wasi) .{ .read = true, .write = true } else .{ .ACCMODE = .RDWR });
    pub const O_SYNC = openFlags(if (builtin.target.os.tag == .linux) .{ .SYNC = true, .DSYNC = true } else .{ .SYNC = true });
    pub const O_TRUNC = openFlags(.{ .TRUNC = true });
    pub const O_WRONLY = openFlags(if (wasi) .{ .write = true } else .{ .ACCMODE = .WRONLY });

    /// `posix_spawn_file_actions_t`, which the runtime only allocates and
    /// passes by pointer. macOS and FreeBSD define it as a pointer; glibc and
    /// musl as an 80-byte structure on a 64-bit target, and musl and
    /// wasi-libc as 76 bytes on a 32-bit one.
    pub const posix_spawn_file_actions_t = extern struct {
        bytes: [if (darwin or freebsd) @sizeOf(usize) else if (@sizeOf(usize) == 8) 80 else 76]u8 align(@alignOf(usize)),
    };

    /// `FILENAME_MAX`, which each libc sets to its `PATH_MAX`.
    pub const FILENAME_MAX = path_max;

    /// The leading fields of wasi-libc's `struct dirent`. The name is a
    /// flexible array that begins after `d_type`.
    pub const struct_dirent = extern struct {
        d_ino: u64,
        d_type: u8,
    };

    /// wasi-libc's `readdir`, which `std.c` types as returning `void`.
    pub extern "c" fn readdir(dir: *anyopaque) ?*struct_dirent;

    /// The name of a wasi-libc directory entry.
    pub fn direntName(entry: *struct_dirent) [*:0]const u8 {
        const base: [*]const u8 = @ptrCast(entry);
        return @ptrCast(base + @offsetOf(struct_dirent, "d_type") + 1);
    }

    // Windows: `CreateFileA`'s arguments, `FormatMessageA`'s and the handle
    // flag. Zig 0.17's `std.os.windows` declares `MAX_PATH`,
    // `SECURITY_ATTRIBUTES` and `STARTF_USESTDHANDLES`, and none of the rest.

    pub const CREATE_ALWAYS = 2;
    pub const CREATE_NEW = 1;
    pub const DUPLICATE_SAME_ACCESS = 0x00000002;
    pub const FILE_APPEND_DATA = 0x0004;
    pub const FILE_ATTRIBUTE_HIDDEN = 0x0002;
    pub const FILE_ATTRIBUTE_NORMAL = 0x0080;
    pub const FILE_ATTRIBUTE_OFFLINE = 0x1000;
    pub const FILE_ATTRIBUTE_READONLY = 0x0001;
    pub const FILE_ATTRIBUTE_TEMPORARY = 0x0100;
    pub const FILE_FLAG_DELETE_ON_CLOSE = 0x04000000;
    pub const FILE_FLAG_NO_BUFFERING = 0x20000000;
    pub const FILE_FLAG_OVERLAPPED = 0x40000000;
    pub const FILE_SHARE_DELETE = 0x00000004;
    pub const FILE_SHARE_READ = 0x00000001;
    pub const FILE_SHARE_WRITE = 0x00000002;
    pub const FILE_TYPE_CHAR = 0x0002;
    pub const FORMAT_MESSAGE_FROM_SYSTEM = 0x00001000;
    pub const FORMAT_MESSAGE_IGNORE_INSERTS = 0x00000200;
    pub const GENERIC_READ = 0x80000000;
    pub const GENERIC_WRITE = 0x40000000;
    pub const HANDLE_FLAG_INHERIT = 0x00000001;
    pub const INVALID_HANDLE_VALUE: ?*anyopaque = @ptrFromInt(std.math.maxInt(usize));
    pub const LANG_NEUTRAL = 0x00;
    pub const MAX_PATH = std.os.windows.MAX_PATH;
    pub const OPEN_ALWAYS = 4;
    pub const OPEN_EXISTING = 3;
    pub const SECURITY_ATTRIBUTES = std.os.windows.SECURITY_ATTRIBUTES;
    pub const STARTF_USESTDHANDLES = std.os.windows.STARTF_USESTDHANDLES;
    pub const SUBLANG_DEFAULT = 0x01;
    pub const TRUNCATE_EXISTING = 5;
    pub const _O_RDONLY = 0x0000;
    pub const _O_WRONLY = 0x0001;

    /// `MAKELANGID`: the sublanguage above the primary language.
    pub fn MAKELANGID(primary: u16, sub: u16) u16 {
        return (sub << 10) | primary;
    }

    /// `PROCESS_INFORMATION`, which `CreateProcessA` fills.
    pub const PROCESS_INFORMATION = extern struct {
        hProcess: ?*anyopaque,
        hThread: ?*anyopaque,
        dwProcessId: u32,
        dwThreadId: u32,
    };

    /// `STARTUPINFOA`, which `CreateProcessA` reads.
    pub const STARTUPINFOA = extern struct {
        cb: u32,
        lpReserved: ?[*:0]u8,
        lpDesktop: ?[*:0]u8,
        lpTitle: ?[*:0]u8,
        dwX: u32,
        dwY: u32,
        dwXSize: u32,
        dwYSize: u32,
        dwXCountChars: u32,
        dwYCountChars: u32,
        dwFillAttribute: u32,
        dwFlags: u32,
        wShowWindow: u16,
        cbReserved2: u16,
        lpReserved2: ?*u8,
        hStdInput: ?*anyopaque,
        hStdOutput: ?*anyopaque,
        hStdError: ?*anyopaque,
    };

    /// mingw's `_finddata_t`, which is `_finddata64i32_t`: 64-bit times and a
    /// 32-bit size.
    pub const _finddata_t = extern struct {
        attrib: c_uint,
        time_create: i64,
        time_access: i64,
        time_write: i64,
        size: c_ulong,
        name: [260]u8,
    };

    pub extern "kernel32" fn CreateFileA(
        path: [*:0]const u8,
        access: u32,
        share: u32,
        attrs: ?*SECURITY_ATTRIBUTES,
        disposition: u32,
        flags: u32,
        template: ?*anyopaque,
    ) callconv(.winapi) ?*anyopaque;

    /// mingw's `_findfirst` and `_findnext`, which its `<io.h>` maps onto the
    /// `64i32` symbols that fill `_finddata64i32_t`.
    pub const _findfirst = _findfirst64i32;
    pub const _findnext = _findnext64i32;
    pub extern "c" fn _findclose(handle: isize) c_int;
    extern "c" fn _findfirst64i32(pattern: [*]const u8, data: *_finddata_t) isize;
    extern "c" fn _findnext64i32(handle: isize, data: *_finddata_t) c_int;

    /// The `int` value of a set of `open` flags.
    fn openFlags(comptime flags: std.c.O) c_int {
        if (windows) @compileError("Windows opens a file with CreateFileA");
        return @bitCast(@as(@typeInfo(std.c.O).@"struct".backing_integer.?, @bitCast(flags)));
    }
};

// ==========================================================================
// Public functions
// ==========================================================================

/// The two Windows APIs whose signatures name a type from `sys`.
///
/// `callconv(.winapi)`, not `.c`. `os/process.zig` declared both `.c`, and
/// `ev/stream.zig` declared its own `CreatePipe` `extern "kernel32"` with
/// `.winapi` three files away. The two are the same convention on x86-64
/// Windows only by accident of the target; `.winapi` is what the header says
/// and what the other declaration already used.
pub extern "kernel32" fn CreatePipe(
    read: *host.Handle,
    write: *host.Handle,
    attrs: *sys.SECURITY_ATTRIBUTES,
    size: u32,
) callconv(.winapi) c_int;

pub extern "kernel32" fn CreateProcessA(
    application: ?[*:0]const u8,
    command_line: ?[*]u8,
    proc_attrs: ?*sys.SECURITY_ATTRIBUTES,
    thread_attrs: ?*sys.SECURITY_ATTRIBUTES,
    inherit: c_int,
    flags: u32,
    environment: ?*anyopaque,
    current_directory: ?[*:0]const u8,
    startup: *sys.STARTUPINFOA,
    info: *sys.PROCESS_INFORMATION,
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
pub extern fn _gmtime64_s(out: *sys.struct_tm, t: *const sys.time_t) callconv(.c) c_int;

pub extern fn _localtime64_s(out: *sys.struct_tm, t: *const sys.time_t) callconv(.c) c_int;

pub extern fn _mkgmtime(t: *sys.struct_tm) callconv(.c) sys.time_t;

pub extern fn chmod(path: [*:0]const u8, mode: jmode_t) callconv(.c) c_int;

/// The environment vector as it stands.
pub inline fn getEnviron() EnvironVector {
    return environPtr().*;
}

pub extern fn gmtime_r(t: *const sys.time_t, out: *sys.struct_tm) callconv(.c) ?*sys.struct_tm;

pub extern fn localtime_r(t: *const sys.time_t, out: *sys.struct_tm) callconv(.c) ?*sys.struct_tm;

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

pub extern fn mktime(t: *sys.struct_tm) callconv(.c) sys.time_t;

pub extern fn posix_spawn(
    pid: *sys.pid_t,
    path: [*:0]const u8,
    actions: ?*const sys.posix_spawn_file_actions_t,
    attrp: ?*const anyopaque,
    argv: [*:null]const ?[*:0]const u8,
    envp: ?[*]?[*:0]u8,
) callconv(.c) c_int;

pub extern fn posix_spawn_file_actions_addchdir(actions: *sys.posix_spawn_file_actions_t, path: [*:0]const u8) callconv(.c) c_int;

pub extern fn posix_spawn_file_actions_addchdir_np(actions: *sys.posix_spawn_file_actions_t, path: [*:0]const u8) callconv(.c) c_int;

pub extern fn posix_spawn_file_actions_addclose(actions: *sys.posix_spawn_file_actions_t, fd: c_int) callconv(.c) c_int;

pub extern fn posix_spawn_file_actions_adddup2(actions: *sys.posix_spawn_file_actions_t, fd: c_int, newfd: c_int) callconv(.c) c_int;

pub extern fn posix_spawn_file_actions_destroy(actions: *sys.posix_spawn_file_actions_t) callconv(.c) c_int;

pub extern fn posix_spawn_file_actions_init(actions: *sys.posix_spawn_file_actions_t) callconv(.c) c_int;

pub extern fn posix_spawnp(
    pid: *sys.pid_t,
    file: [*:0]const u8,
    actions: ?*const sys.posix_spawn_file_actions_t,
    attrp: ?*const anyopaque,
    argv: [*:null]const ?[*:0]const u8,
    envp: ?[*]?[*:0]u8,
) callconv(.c) c_int;

/// Replaces the environment vector, which `os/posix-exec` does.
pub inline fn setEnviron(value: EnvironVector) void {
    environPtr().* = value;
}

pub extern fn sigaction(sig: c_int, act: *const sys.struct_sigaction, old: ?*sys.struct_sigaction) callconv(.c) c_int;

pub extern fn sigaddset(set: *sys.sigset_t, sig: c_int) callconv(.c) c_int;

pub extern fn sigemptyset(set: *sys.sigset_t) callconv(.c) c_int;

pub extern fn sigprocmask(how: c_int, set: *const sys.sigset_t, old: ?*sys.sigset_t) callconv(.c) c_int;

pub extern fn strftime(buf: [*]u8, size: usize, fmt: [*:0]const u8, t: *const sys.struct_tm) callconv(.c) usize;

pub extern fn time(t: ?*sys.time_t) callconv(.c) sys.time_t;

pub extern fn timegm(t: *sys.struct_tm) callconv(.c) sys.time_t;

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
    return switch (builtin.target.os.tag) {
        .macos, .ios, .tvos, .watchos, .visionos => _NSGetEnviron(),
        // mingw's `_environ` is a macro over `__p__environ()`, and only the
        // accessor is a symbol its import library exports.
        .windows => __p__environ(),
        else => &environ,
    };
}
