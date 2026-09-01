//! The C-ABI namespace, in Zig.
//!
//! `c` is this file. Every name in it is genuinely external -- libc, and the
//! few crossings a caller wants for their behaviour rather than by accident --
//! declared in Zig against Zig types.
//!
//! **An `extern fn` is a promise the compiler believes without reading.** A
//! declaration here that disagrees with the definition it names would link and
//! run, and the disagreement would be undiagnosed. `cabi_check.zig` compares
//! every one of them against its definition, by exact type equality, on every
//! build; what it cannot reach is named in that file.
//!
//! **This file declares functions and nothing else.** A type or a constant is
//! imported from the file that owns it, by the file that names it; there are
//! no re-exported aliases here for a call site to reach a neighbour's
//! declaration through. Zig 0.15.1's release notes give the rationale for
//! removing `usingnamespace` as *"namespacing is good, actually"*, and a
//! flattening alias is what that keyword was removed to discourage.
//!
//! **`janet_vm` is not declared here**, and could not be: it is the one symbol
//! whose storage class follows the build -- `threadlocal` unless
//! `-Dsingle-threaded` -- and a container-level declaration cannot be
//! conditional. Every caller reaches the state through `vm/state.zig`'s
//! `current()`, which takes the address of the variable directly.

const std = @import("std");
const builtin = @import("builtin");
const repr = @import("repr");
const host = @import("host");

/// Two constants that are libc's rather than Janet's. libc through `@cImport`
/// is deliberate: "no C in the tree" and "no libc" are different claims, and
/// only the first is a goal.
const libc = @cImport({
    @cInclude("stdio.h");
});

pub const BUFSIZ = libc.BUFSIZ;
pub const EOF = libc.EOF;

// ---------------------------------------------------------------------------
// The declarations. Everything below is genuinely external: libc, and the few
// crossings a caller wants for their behaviour rather than by accident.
// `cabi_check.zig` compares each one against the definition it names.
// ---------------------------------------------------------------------------

pub extern fn abort() noreturn;
pub extern fn acos(f64) f64;
pub extern fn acosh(f64) f64;
pub extern fn asin(f64) f64;
pub extern fn asinh(f64) f64;
pub extern fn atan(f64) f64;
pub extern fn atan2(f64, f64) f64;
pub extern fn atanh(f64) f64;
pub extern fn cbrt(f64) f64;
pub extern fn ceil(f64) f64;
pub extern fn cos(f64) f64;
pub extern fn cosh(f64) f64;
pub extern fn erf(f64) f64;
pub extern fn erfc(f64) f64;
pub extern fn exit(c_int) noreturn;
pub extern fn exp(f64) f64;
pub extern fn exp2(f64) f64;
pub extern fn expm1(f64) f64;
pub extern fn fabs(f64) f64;
pub extern fn fclose(?*host.FILE) c_int;
pub extern fn feof(?*host.FILE) c_int;
pub extern fn fflush(?*host.FILE) c_int;
pub extern fn fgetc(?*host.FILE) c_int;
pub extern fn floor(f64) f64;
pub extern fn fopen(noalias __filename: [*:0]const u8, noalias __mode: [*:0]const u8) ?*host.FILE;
pub extern fn fprintf(noalias ?*host.FILE, noalias [*:0]const u8, ...) c_int;
pub extern fn fputs(noalias [*:0]const u8, noalias ?*host.FILE) c_int;
pub extern fn fread(noalias __ptr: ?*anyopaque, __size: usize, __nitems: usize, noalias __stream: ?*host.FILE) usize;
pub extern fn frexp(f64, *c_int) f64;
pub extern fn fwrite(noalias __ptr: ?*const anyopaque, __size: usize, __nitems: usize, noalias __stream: ?*host.FILE) usize;
pub extern fn hypot(f64, f64) f64;
pub extern fn janet_cstring(str: [*:0]const u8) [*:0]const u8;
pub extern fn janet_wrap_string(x: [*:0]const u8) repr.Value;
pub extern fn janet_zig_c_raise_record() void;
pub extern fn janet_zig_c_raise_take() c_int;
pub extern fn janet_zig_fatal(message: [*:0]const u8) noreturn;
pub extern fn janet_zig_signal_record(sig: c_uint, message: repr.Value) void;
pub extern fn ldexp(f64, c_int) f64;
pub extern fn lgamma(f64) f64;
pub extern fn log(f64) f64;
pub extern fn log10(f64) f64;
pub extern fn log1p(f64) f64;
pub extern fn log2(f64) f64;
pub extern fn memcmp(__s1: ?*const anyopaque, __s2: ?*const anyopaque, __n: usize) c_int;
pub extern fn memcpy(__dst: ?*anyopaque, __src: ?*const anyopaque, __n: usize) ?*anyopaque;
pub extern fn memset(__b: ?*anyopaque, __c: c_int, __len: usize) ?*anyopaque;
pub extern fn nextafter(f64, f64) f64;
pub extern fn pow(f64, f64) f64;
pub extern fn remove([*:0]const u8) c_int;
pub extern fn rewind(?*host.FILE) void;
pub extern fn round(f64) f64;
pub extern fn sin(f64) f64;
pub extern fn sinh(f64) f64;
pub extern fn snprintf(noalias __str: [*]u8, __size: usize, noalias __format: [*:0]const u8, ...) c_int;
pub extern fn sqrt(f64) f64;
pub extern fn strlen(__s: [*:0]const u8) usize;
pub extern fn strncmp(__s1: [*]const u8, __s2: [*]const u8, __n: usize) c_int;
pub extern fn tan(f64) f64;
pub extern fn tanh(f64) f64;
pub extern fn tgamma(f64) f64;
pub extern fn tmpfile() ?*host.FILE;
pub extern fn trunc(f64) f64;

// used by `vm.zig`
/// `fmod` from `<math.h>`. `@rem` has the same rounding for finite operands but
/// is not defined over infinities the way the C library function is, and
/// `JOP_REMAINDER` is reachable with either.
pub extern fn fmod(x: f64, y: f64) f64;

// used by `signal.zig`
pub extern fn pthread_exit(val: ?*anyopaque) callconv(.c) noreturn;

// used by `utils.zig`
pub extern fn strerror(e: c_int) callconv(.c) [*]u8;

/// The XSI signature, which is the one every libc in this project's reach but
/// glibc actually has.
pub extern fn strerror_r(e: c_int, buf: [*]u8, len: usize) callconv(.c) c_int;

pub extern fn arc4random_buf(buf: [*]u8, nbytes: usize) callconv(.c) void;

pub extern fn rand_s(v: *c_uint) callconv(.c) c_int;

// used by `ffi/call.zig`
pub extern fn VirtualAlloc(addr: ?*anyopaque, size: usize, alloc_type: u32, protect: u32) callconv(.c) ?*anyopaque;

pub extern fn VirtualProtect(addr: *anyopaque, size: usize, protect: u32, old: *u32) callconv(.c) c_int;

pub extern fn VirtualFree(addr: *anyopaque, size: usize, free_type: u32) callconv(.c) c_int;

// used by `os/fs/open.zig`
pub extern fn open(path: [*:0]const u8, flags: c_int, ...) callconv(.c) c_int;

// used by `os/fs/host_stat.zig`
pub extern fn fileno(stream: ?*anyopaque) callconv(.c) c_int;

// used by `stdio.zig`
pub extern fn __acrt_iob_func(index: c_uint) callconv(.c) ?*host.FILE;

pub extern var __stdinp: ?*host.FILE;

pub extern var __stdoutp: ?*host.FILE;

pub extern var __stderrp: ?*host.FILE;

pub extern var stdin: ?*host.FILE;

pub extern var stdout: ?*host.FILE;

pub extern var stderr: ?*host.FILE;

// used by `dynlib.zig`
pub extern "kernel32" fn GetModuleHandleA(name: ?[*:0]const u8) callconv(.winapi) ?*anyopaque;

pub extern "kernel32" fn LoadLibraryA(name: [*:0]const u8) callconv(.winapi) ?*anyopaque;

pub extern "kernel32" fn FreeLibrary(module: ?*anyopaque) callconv(.winapi) c_int;

pub extern "kernel32" fn GetProcAddress(module: ?*anyopaque, name: [*:0]const u8) callconv(.winapi) ?*anyopaque;

pub extern "kernel32" fn GetLastError() callconv(.winapi) u32;

pub extern "kernel32" fn GetCurrentProcess() callconv(.winapi) ?*anyopaque;

pub extern "kernel32" fn FormatMessageA(
    flags: u32,
    source: ?*const anyopaque,
    message_id: u32,
    language_id: u32,
    buffer: [*]u8,
    size: u32,
    arguments: ?*anyopaque,
) callconv(.winapi) u32;

/// `psapi`, which `build.zig` links for Windows and which `util.c` includes
/// `<psapi.h>` for.
pub extern "psapi" fn EnumProcessModules(
    process: ?*anyopaque,
    modules: [*]?*anyopaque,
    size: u32,
    needed: *u32,
) callconv(.winapi) c_int;

// used by `ev/stream.zig`
pub extern fn recv(fd: c_int, buf: [*]u8, len: usize, flags: c_int) callconv(.c) isize;

pub extern fn recvfrom(fd: c_int, buf: [*]u8, len: usize, flags: c_int, from: ?*anyopaque, fromlen: *c_uint) callconv(.c) isize;

pub extern fn send(fd: c_int, buf: [*]const u8, len: usize, flags: c_int) callconv(.c) isize;

pub extern fn sendto(fd: c_int, buf: [*]const u8, len: usize, flags: c_int, to: ?*const anyopaque, tolen: c_uint) callconv(.c) isize;

pub extern "kernel32" fn DuplicateHandle(src_proc: ?*anyopaque, src: ?*anyopaque, dst_proc: ?*anyopaque, dst: *?*anyopaque, access: u32, inherit: c_int, options: u32) callconv(.winapi) c_int;

pub extern "kernel32" fn GetCurrentProcessId() callconv(.winapi) u32;

pub extern fn _open_osfhandle(h: isize, flags: c_int) callconv(.c) c_int;

pub extern fn _dup(fd: c_int) callconv(.c) c_int;

pub extern fn _close(fd: c_int) callconv(.c) c_int;

pub extern fn _fdopen(fd: c_int, mode: [*:0]const u8) callconv(.c) ?*host.FILE;

// used by `os.zig`

pub extern fn setlocale(category: c_int, locale: ?[*:0]const u8) callconv(.c) ?[*:0]const u8;

pub extern fn isatty(fd: c_int) callconv(.c) c_int;

pub extern fn _isatty(fd: c_int) callconv(.c) c_int;

pub extern fn _fileno(f: ?*anyopaque) callconv(.c) c_int;

pub extern "kernel32" fn QueryPerformanceCounter(*i64) callconv(.winapi) c_int;

pub extern "kernel32" fn QueryPerformanceFrequency(*i64) callconv(.winapi) c_int;

pub extern "kernel32" fn Sleep(u32) callconv(.winapi) void;

pub extern fn getenv(name: [*:0]const u8) callconv(.c) ?[*:0]const u8;

pub extern fn setenv(name: [*:0]const u8, value: [*:0]const u8, overwrite: c_int) callconv(.c) c_int;

pub extern fn unsetenv(name: [*:0]const u8) callconv(.c) c_int;

pub extern fn _putenv_s(name: [*:0]const u8, value: [*:0]const u8) callconv(.c) c_int;

// used by `os/fs.zig`
/// The host allocates the path and this frees it, on the POSIX/Windows split
/// `FOUND.md` records: `canonicalPath` is `realpath` on POSIX and
/// `_fullpath` on Windows, and the Windows result is released with the plain
/// `free` rather than Janet's, because `_fullpath` used the plain `malloc`.
///
/// The `janet_cstringv` between the allocation and the release can raise, and
/// a raise here strands the allocation. That is the C original's behaviour,
/// reproduced rather than repaired with a `defer`.
pub extern fn free(ptr: ?*anyopaque) callconv(.c) void;

pub extern fn GetFileAttributesA(name: [*:0]const u8) callconv(.c) u32;

pub extern fn _chmod(path: [*:0]const u8, mode: c_int) callconv(.c) c_int;

pub extern fn _umask(mask: c_int) callconv(.c) c_int;

pub extern fn getcwd(buffer: [*]u8, size: usize) callconv(.c) ?[*]u8;

pub extern fn _getcwd(buffer: [*]u8, size: c_int) callconv(.c) ?[*]u8;

pub extern fn mkdir(path: [*:0]const u8, mode: c_uint) callconv(.c) c_int;

pub extern fn _mkdir(path: [*:0]const u8) callconv(.c) c_int;

pub extern fn rmdir(path: [*:0]const u8) callconv(.c) c_int;

pub extern fn _rmdir(path: [*:0]const u8) callconv(.c) c_int;

pub extern fn chdir(path: [*:0]const u8) callconv(.c) c_int;

pub extern fn _chdir(path: [*:0]const u8) callconv(.c) c_int;

pub extern fn rename(old_path: [*:0]const u8, new_path: [*:0]const u8) callconv(.c) c_int;

pub extern fn link(oldpath: [*:0]const u8, newpath: [*:0]const u8) callconv(.c) c_int;

pub extern fn realpath(path: [*:0]const u8, resolved: ?[*]u8) callconv(.c) ?[*:0]u8;

pub extern fn _fullpath(resolved: ?[*]u8, path: [*:0]const u8, size: c_int) callconv(.c) ?[*:0]u8;

pub extern fn _Exit(status: c_int) callconv(.c) noreturn;

// used by `io.zig`
pub extern fn dup(fd: c_int) callconv(.c) c_int;

// used by `ev.zig`
pub extern fn write(fd: c_int, buf: [*]const u8, count: usize) callconv(.c) isize;

pub extern fn read(fd: c_int, buf: [*]u8, count: usize) callconv(.c) isize;

pub extern fn close(fd: c_int) callconv(.c) c_int;

pub extern fn sleep(seconds: c_uint) callconv(.c) c_uint;

pub extern fn pipe(fds: *[2]c_int) callconv(.c) c_int;

pub extern fn fcntl(fd: c_int, cmd: c_int, ...) callconv(.c) c_int;

pub extern fn fdopen(fd: c_int, mode: [*:0]const u8) callconv(.c) ?*host.FILE;

pub extern fn pthread_attr_init(attr: *host.pthread_attr_t) callconv(.c) c_int;

pub extern fn pthread_attr_destroy(attr: *host.pthread_attr_t) callconv(.c) c_int;

pub extern fn pthread_attr_setdetachstate(attr: *host.pthread_attr_t, state: c_int) callconv(.c) c_int;

pub extern fn pthread_create(
    thread: *host.pthread_t,
    attr: ?*const host.pthread_attr_t,
    start: *const fn (?*anyopaque) callconv(.c) ?*anyopaque,
    arg: ?*anyopaque,
) callconv(.c) c_int;

pub extern fn pthread_join(thread: host.pthread_t, res: *?*anyopaque) callconv(.c) c_int;

pub extern fn pthread_cancel(thread: host.pthread_t) callconv(.c) c_int;

pub extern fn pthread_kill(thread: host.pthread_t, sig: c_int) callconv(.c) c_int;

pub extern "kernel32" fn GetTickCount64() callconv(.winapi) u64;

pub extern "kernel32" fn CloseHandle(h: ?*anyopaque) callconv(.winapi) c_int;

pub extern "kernel32" fn SetEvent(h: ?*anyopaque) callconv(.winapi) c_int;

pub extern "kernel32" fn CreateEventA(attrs: ?*anyopaque, manual: c_int, initial: c_int, name: ?[*:0]const u8) callconv(.winapi) ?*anyopaque;

pub extern "kernel32" fn WaitForSingleObject(h: ?*anyopaque, ms: u32) callconv(.winapi) u32;

pub extern "kernel32" fn ResumeThread(h: ?*anyopaque) callconv(.winapi) u32;

pub extern "kernel32" fn CreateThread(
    attrs: ?*anyopaque,
    stack: usize,
    start: *const fn (?*anyopaque) callconv(.winapi) u32,
    arg: ?*anyopaque,
    flags: u32,
    id: ?*u32,
) callconv(.winapi) ?*anyopaque;

pub extern "kernel32" fn PostQueuedCompletionStatus(
    port: ?*anyopaque,
    bytes: u32,
    key: usize,
    overlapped: ?*anyopaque,
) callconv(.winapi) c_int;

// used by `os/process.zig`
pub extern fn GetExitCodeProcess(handle: host.Handle, code: *u32) callconv(.c) c_int;

pub extern fn TerminateProcess(handle: host.Handle, code: c_uint) callconv(.c) c_int;

pub extern fn SetHandleInformation(handle: host.Handle, mask: u32, flags: u32) callconv(.c) c_int;

pub extern fn _get_osfhandle(fd: c_int) callconv(.c) isize;

pub extern fn _getpid() callconv(.c) c_int;

pub extern fn system(command: ?[*:0]const u8) callconv(.c) c_int;

pub extern fn chroot(path: [*:0]const u8) callconv(.c) c_int;

pub extern fn execv(path: [*:0]const u8, argv: [*:null]const ?[*:0]const u8) callconv(.c) c_int;

pub extern fn execvp(file: [*:0]const u8, argv: [*:null]const ?[*:0]const u8) callconv(.c) c_int;

// ==========================================================================
// The one accessor that is not a declaration
// ==========================================================================

/// `errno`, which is a macro in every libc and therefore not a symbol.
///
/// Eleven files defined this identically -- `os.zig`, `os/fs.zig`,
/// `os/fs/open.zig`, `os/fs/stat.zig`, `os/date.zig`, `os/process.zig`,
/// `ev.zig`, `net.zig`, `filewatch.zig`, `io.zig` and `utils.zig` -- because
/// each needed it and none could reach a neighbour's. It belongs with the rest
/// of what is genuinely external.
pub inline fn errno() c_int {
    return std.c._errno().*;
}

/// Write `errno`. One caller: `os/fs.zig`'s directory walk clears it before
/// each `readdir`, because a null result there means either the end of the
/// stream or a failure and only `errno` separates them. It is a setter rather
/// than a `_errno()` at the call site so that `std.c._errno` has exactly one
/// mention in the tree, which is what makes "the seam is here" checkable.
pub inline fn setErrno(value: c_int) void {
    std.c._errno().* = value;
}

/// `EINTR`, once. It was spelled four ways -- `h.EINTR` out of three different
/// translated headers, `ev.EINTR`, `utils.EINTR`, and the bare
/// `@intFromEnum(std.c.E.INTR)` -- which is three chances for two of them to
/// mean different numbers on a target nobody built.
pub const eintr: c_int = @intFromEnum(std.c.E.INTR);

/// Call `f(args)` again for as long as it fails because a signal interrupted
/// it, and answer whatever it finally returned.
///
/// Thirty retry loops were written out, each three lines, and writing them out
/// is how two of them came to be wrong: `FOUND.md`'s "The kqueue backend's
/// initialisation retries on every error except `EINTR`" and "`filewatch/remove`
/// retries a call that succeeded". Both were faithful copies of `ev.c` and
/// `filewatch.c`, and both are fixed by there being one loop.
///
/// The failure test is `< 0`, which is every call this wraps: `close`, `read`,
/// `write`, `open`, `kevent`, `epoll_wait`, `inotify_rm_watch`, `waitpid` and
/// the rest all answer a negative on failure and set `errno`. **A call whose
/// failure is not negative does not belong here** -- it would need its own
/// predicate, and inventing one for a caller that does not exist is how a
/// helper starts being wrong.
pub inline fn retryIntr(comptime f: anytype, args: anytype) @TypeOf(@call(.auto, f, args)) {
    while (true) {
        const result = @call(.auto, f, args);
        if (result >= 0 or errno() != eintr) return result;
    }
}

// used by `io.zig`
pub extern fn fputc(ch: c_int, file: ?*host.FILE) callconv(.c) c_int;

pub extern fn ferror(file: ?*host.FILE) callconv(.c) c_int;

pub extern fn setvbuf(file: ?*host.FILE, buffer: ?[*]u8, mode: c_int, size: usize) callconv(.c) c_int;

pub extern fn fseek(file: ?*host.FILE, offset: c_long, whence: c_int) callconv(.c) c_int;

pub extern fn ftell(file: ?*host.FILE) callconv(.c) c_long;

/// Janet redirects `fseek` and `ftell` to the 64-bit Microsoft variants, so the
/// port calls what the C implementation calls rather than the narrow ones.
pub extern fn _fseeki64(file: ?*host.FILE, offset: i64, whence: c_int) callconv(.c) c_int;

pub extern fn _ftelli64(file: ?*host.FILE) callconv(.c) i64;

// used by `os/date.zig`
pub extern fn tzset() callconv(.c) void;

pub extern fn _tzset() callconv(.c) void;

// ==========================================================================
// The host shapes the declarations above name
// ==========================================================================
//
// Four aliases and one struct, here rather than in the subsystem that calls
// through them, because a declaration and the type in its signature belong
// together and the declaration belongs here. Each is a fact about the host's
// interface rather than about what a subsystem does with it.
//
// The host *headers* stay where they are: `os/abi.h`, `net/abi.h` and
// `filewatch/abi.h` are translations, and a translated type is that
// translation's. What is below is what Zig can state directly.

/// `time_t`, which mingw widens to 64 bits whatever the pointer width is.
pub const TimeT = if (builtin.os.tag == .windows) i64 else std.c.time_t;

/// `pid_t`. Windows has no such thing; the process subsystem uses a `c_int`
/// there and never passes it to a host call.
pub const pid_t = if (builtin.os.tag == .windows) c_int else std.c.pid_t;

/// `FILETIME`, the 64-bit tick count Windows reports times in.
pub const FILETIME = extern struct {
    low: u32,
    high: u32,
};

/// `CRITICAL_SECTION` and `SRWLOCK`, which `ev/locks.zig` allocates by size.
pub const CriticalSection = if (builtin.os.tag == .windows) std.os.windows.CRITICAL_SECTION else void;
pub const SrwLock = if (builtin.os.tag == .windows) ?*anyopaque else void;

// used by `os.zig`
pub extern "kernel32" fn GetSystemTimeAsFileTime(*FILETIME) callconv(.winapi) void;

pub extern "kernel32" fn GetProcessTimes(?*anyopaque, *FILETIME, *FILETIME, *FILETIME, *FILETIME) callconv(.winapi) c_int;

pub extern fn time(?*TimeT) callconv(.c) TimeT;

// used by `os/process.zig`
pub extern fn getpid() callconv(.c) pid_t;

pub extern fn waitpid(pid: pid_t, status: *c_int, options: c_int) callconv(.c) pid_t;

pub extern fn kill(pid: pid_t, sig: c_int) callconv(.c) c_int;

pub extern fn fork() callconv(.c) pid_t;

// used by `ev/locks.zig`
pub extern fn InitializeCriticalSection(cs: *CriticalSection) callconv(.winapi) void;

pub extern fn DeleteCriticalSection(cs: *CriticalSection) callconv(.winapi) void;

pub extern fn EnterCriticalSection(cs: *CriticalSection) callconv(.winapi) void;

pub extern fn LeaveCriticalSection(cs: *CriticalSection) callconv(.winapi) void;

pub extern fn InitializeSRWLock(lock: *SrwLock) callconv(.winapi) void;

pub extern fn AcquireSRWLockShared(lock: *SrwLock) callconv(.winapi) void;

pub extern fn AcquireSRWLockExclusive(lock: *SrwLock) callconv(.winapi) void;

pub extern fn ReleaseSRWLockShared(lock: *SrwLock) callconv(.winapi) void;

pub extern fn ReleaseSRWLockExclusive(lock: *SrwLock) callconv(.winapi) void;

/// `OVERLAPPED`, the asynchronous-I/O record every Windows overlapped call
/// takes. `ev/stream.zig` embeds one in `JanetStream`'s Windows arm.
pub const OVERLAPPED = extern struct {
    Internal: usize,
    InternalHigh: usize,
    Offset: u32,
    OffsetHigh: u32,
    hEvent: ?*anyopaque,
};

/// `SECURITY_ATTRIBUTES`, as much of it as the pipe calls need.
pub const SecurityAttributes = extern struct {
    nLength: u32,
    lpSecurityDescriptor: ?*anyopaque,
    bInheritHandle: c_int,
};

/// `struct epoll_event` and `struct itimerspec`, the two Linux shapes the
/// epoll backend passes by pointer.
pub const EpollEvent = if (builtin.os.tag == .linux) std.os.linux.epoll_event else void;
pub const ITimerSpec = extern struct {
    it_interval: std.c.timespec,
    it_value: std.c.timespec,
};

/// `struct utimbuf`, which `os/touch` fills.
pub const utimbuf = extern struct {
    actime: TimeT,
    modtime: TimeT,
};

// used by `ev/stream.zig`
pub extern "kernel32" fn ReadFile(h: ?*anyopaque, buf: [*]u8, count: u32, read_out: ?*u32, ov: ?*OVERLAPPED) callconv(.winapi) c_int;

pub extern "kernel32" fn WriteFile(h: ?*anyopaque, buf: [*]const u8, count: u32, written: ?*u32, ov: ?*OVERLAPPED) callconv(.winapi) c_int;

pub extern "kernel32" fn CreatePipe(read: *?*anyopaque, write: *?*anyopaque, attrs: ?*SecurityAttributes, size: u32) callconv(.winapi) c_int;

pub extern "kernel32" fn CreateNamedPipeA(name: [*:0]const u8, open_mode: u32, pipe_mode: u32, max_instances: u32, out_size: u32, in_size: u32, timeout: u32, attrs: ?*SecurityAttributes) callconv(.winapi) ?*anyopaque;

pub extern "kernel32" fn CreateFileA(name: [*:0]const u8, access: u32, share: u32, attrs: ?*SecurityAttributes, disposition: u32, flags: u32, template: ?*anyopaque) callconv(.winapi) ?*anyopaque;

// used by `os/fs.zig`

pub extern fn utime(path: [*:0]const u8, times: ?*const utimbuf) callconv(.c) c_int;

/// The MinGW CRT resolves `utime` to the 64-bit variant, which is what Janet's
/// C implementation calls.
pub extern fn _utime64(path: [*:0]const u8, times: ?*const utimbuf) callconv(.c) c_int;

// used by `ev/backend.zig`
pub extern "kernel32" fn CreateIoCompletionPort(file: ?*anyopaque, port: ?*anyopaque, key: usize, threads: u32) callconv(.winapi) ?*anyopaque;
pub extern "kernel32" fn GetQueuedCompletionStatus(port: ?*anyopaque, bytes: *u32, key: *usize, overlapped: *?*OVERLAPPED, ms: u32) callconv(.winapi) c_int;
pub extern fn epoll_create1(flags: c_int) callconv(.c) c_int;
pub extern fn epoll_ctl(epfd: c_int, op: c_int, fd: c_int, event: ?*EpollEvent) callconv(.c) c_int;
pub extern fn epoll_wait(epfd: c_int, events: [*]EpollEvent, maxevents: c_int, timeout: c_int) callconv(.c) c_int;
pub extern fn timerfd_create(clockid: c_int, flags: c_int) callconv(.c) c_int;
pub extern fn timerfd_settime(fd: c_int, flags: c_int, new: *const ITimerSpec, old: ?*ITimerSpec) callconv(.c) c_int;

/// `WSABUF`, the scatter/gather element the two overlapped socket calls take.
pub const WSABUF = extern struct {
    len: u32,
    buf: [*]u8,
};

// from src/zig/ev/stream.zig -- Winsock, which is its own import library
pub extern "ws2_32" fn closesocket(s: usize) callconv(.winapi) c_int;
pub extern "ws2_32" fn WSAGetLastError() callconv(.winapi) c_int;
pub extern "ws2_32" fn WSARecvFrom(s: usize, bufs: [*]WSABUF, count: u32, received: ?*u32, flags: *u32, from: ?*anyopaque, fromlen: ?*i32, ov: ?*OVERLAPPED, routine: ?*anyopaque) callconv(.winapi) c_int;
pub extern "ws2_32" fn WSASendTo(s: usize, bufs: [*]WSABUF, count: u32, sent: ?*u32, flags: u32, to: ?*const anyopaque, tolen: c_int, ov: ?*OVERLAPPED, routine: ?*anyopaque) callconv(.winapi) c_int;
