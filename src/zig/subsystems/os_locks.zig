//! The recursive mutex and the reader/writer lock `ev/lock` and `ev/rwlock`
//! are made of, and the channel's own lock.
//!
//! These were the last twelve symbols `abstract.c` defined, and they sat there
//! rather than anywhere sensible because `JanetOSMutex` is an opaque type in
//! `janet.h` and the file that allocated one had to know its size. Nothing
//! about them needed C: `abi.zig`'s translation of `janet.h` reaches
//! `<pthread.h>` already, so `pthread_mutex_t`, `pthread_rwlock_t`,
//! `pthread_mutexattr_t` and `PTHREAD_MUTEX_RECURSIVE` are all nameable, and
//! the Windows arm is four `kernel32` calls with no structure to lay out
//! beyond `CRITICAL_SECTION`.
//!
//! **The mutex is recursive on purpose.** `PTHREAD_MUTEX_RECURSIVE` is what
//! lets a Janet function holding a lock call another that takes the same one,
//! which `ev/with-lock` relies on. A default mutex deadlocks there instead,
//! and nothing in the suites would say so.
//!
//! `janet_os_mutex_unlock` was the **last `janet_panic` call site compiled
//! into C**. It is a returned raise now, like everything else.

const std = @import("std");
const builtin = @import("builtin");
const abi = @import("abi");
const c = abi.c;
const raise = @import("raise");

const windows = builtin.os.tag == .windows;

/// A translation of `<pthread.h>` alone, and the sixth in the tree.
///
/// `abi.zig` reaches these types already — but only when `janet.h` includes
/// `<pthread.h>`, which it does for the threaded event loop and not for
/// `-Dev=false`. Relying on that was the mistake: the host build compiled and
/// a reduced *configuration* did not, which is rule 13's shape and what the
/// matrix is for.
///
/// Phase 10's rule 3 is the test for adding a translation — it is right when
/// nothing it declares crosses a subsystem boundary — and nothing does. Every
/// caller passes a `JanetOSMutex *`, which `janet.h` declares opaque; the
/// `pthread_*` types stay inside this file.
const sys = if (windows) struct {} else @cImport({
    @cInclude("features.h");
    @cInclude("pthread.h");
});

// `CRITICAL_SECTION` is a structure and an `SRWLOCK` is a single pointer; both
// come from `std.os.windows` rather than from a second translation of
// `<windows.h>`, which is what `os_abi.h`'s note asks for.
const CriticalSection = if (windows) std.os.windows.CRITICAL_SECTION else void;
const SrwLock = if (windows) ?*anyopaque else void;

extern fn InitializeCriticalSection(cs: *CriticalSection) callconv(.winapi) void;
extern fn DeleteCriticalSection(cs: *CriticalSection) callconv(.winapi) void;
extern fn EnterCriticalSection(cs: *CriticalSection) callconv(.winapi) void;
extern fn LeaveCriticalSection(cs: *CriticalSection) callconv(.winapi) void;
extern fn InitializeSRWLock(lock: *SrwLock) callconv(.winapi) void;
extern fn AcquireSRWLockShared(lock: *SrwLock) callconv(.winapi) void;
extern fn AcquireSRWLockExclusive(lock: *SrwLock) callconv(.winapi) void;
extern fn ReleaseSRWLockShared(lock: *SrwLock) callconv(.winapi) void;
extern fn ReleaseSRWLockExclusive(lock: *SrwLock) callconv(.winapi) void;

// ------------------------------------------------------------------ sizes

/// What the caller must allocate. `ev/lock` hands this to
/// `janet_abstract_threaded`, so it is the abstract's payload size.
pub fn mutexSize() usize {
    return if (windows) @sizeOf(CriticalSection) else @sizeOf(sys.pthread_mutex_t);
}

pub fn rwlockSize() usize {
    return if (windows) @sizeOf(SrwLock) else @sizeOf(sys.pthread_rwlock_t);
}

// ------------------------------------------------------------------ mutex

pub fn mutexInit(mutex: *anyopaque) void {
    if (windows) {
        InitializeCriticalSection(@ptrCast(@alignCast(mutex)));
    } else {
        var attr: sys.pthread_mutexattr_t = undefined;
        _ = sys.pthread_mutexattr_init(&attr);
        _ = sys.pthread_mutexattr_settype(&attr, sys.PTHREAD_MUTEX_RECURSIVE);
        _ = sys.pthread_mutex_init(@ptrCast(@alignCast(mutex)), &attr);
    }
}

pub fn mutexDeinit(mutex: *anyopaque) void {
    if (windows) {
        DeleteCriticalSection(@ptrCast(@alignCast(mutex)));
    } else {
        _ = sys.pthread_mutex_destroy(@ptrCast(@alignCast(mutex)));
    }
}

pub fn mutexLock(mutex: *anyopaque) void {
    if (windows) {
        EnterCriticalSection(@ptrCast(@alignCast(mutex)));
    } else {
        _ = sys.pthread_mutex_lock(@ptrCast(@alignCast(mutex)));
    }
}

/// Unlocking is the one of the twelve that can fail, and the C original
/// panicked. It raises by returning now, which is what took the last
/// `janet_panic` call site out of C.
///
/// The Windows arm cannot report: `LeaveCriticalSection` returns `void`, and
/// the C original's comment -- "error handling? May want to keep counter" --
/// records that the author knew. Reproduced rather than repaired; `FOUND.md`
/// has the asymmetry.
pub fn mutexUnlock(mutex: *anyopaque) raise.Raising(void) {
    if (windows) {
        LeaveCriticalSection(@ptrCast(@alignCast(mutex)));
    } else {
        if (sys.pthread_mutex_unlock(@ptrCast(@alignCast(mutex))) != 0)
            return raise.panic("cannot release lock");
    }
}

// ----------------------------------------------------------------- rwlock

pub fn rwlockInit(rwlock: *anyopaque) void {
    if (windows) {
        InitializeSRWLock(@ptrCast(@alignCast(rwlock)));
    } else {
        _ = sys.pthread_rwlock_init(@ptrCast(@alignCast(rwlock)), null);
    }
}

/// A no-op on Windows, as it is in the C: an `SRWLOCK` owns nothing to
/// release. The C says "no op?" with the question mark; it is not a question,
/// and the entry point exists so that the two platforms have the same shape.
pub fn rwlockDeinit(rwlock: *anyopaque) void {
    if (windows) return;
    _ = sys.pthread_rwlock_destroy(@ptrCast(@alignCast(rwlock)));
}

pub fn rwlockRlock(rwlock: *anyopaque) void {
    if (windows) {
        AcquireSRWLockShared(@ptrCast(@alignCast(rwlock)));
    } else {
        _ = sys.pthread_rwlock_rdlock(@ptrCast(@alignCast(rwlock)));
    }
}

pub fn rwlockWlock(rwlock: *anyopaque) void {
    if (windows) {
        AcquireSRWLockExclusive(@ptrCast(@alignCast(rwlock)));
    } else {
        _ = sys.pthread_rwlock_wrlock(@ptrCast(@alignCast(rwlock)));
    }
}

/// Windows needs two release calls where POSIX has one, because an `SRWLOCK`
/// does not record which way it was taken.
pub fn rwlockRunlock(rwlock: *anyopaque) void {
    if (windows) {
        ReleaseSRWLockShared(@ptrCast(@alignCast(rwlock)));
    } else {
        _ = sys.pthread_rwlock_unlock(@ptrCast(@alignCast(rwlock)));
    }
}

pub fn rwlockWunlock(rwlock: *anyopaque) void {
    if (windows) {
        ReleaseSRWLockExclusive(@ptrCast(@alignCast(rwlock)));
    } else {
        _ = sys.pthread_rwlock_unlock(@ptrCast(@alignCast(rwlock)));
    }
}

// ---------------------------------------------------------------- exports

comptime {
    // `janet.h` declares all twelve, so they keep their C names until Phase 11
    // decides the exported surface. Only `janet_os_mutex_unlock` needed a face:
    // it is the one that can raise.
    @export(&mutexSizeFace, .{ .name = "janet_os_mutex_size" });
    @export(&rwlockSizeFace, .{ .name = "janet_os_rwlock_size" });
    @export(&mutexInitFace, .{ .name = "janet_os_mutex_init" });
    @export(&mutexDeinitFace, .{ .name = "janet_os_mutex_deinit" });
    @export(&mutexLockFace, .{ .name = "janet_os_mutex_lock" });
    @export(&mutexUnlockFace, .{ .name = "janet_os_mutex_unlock" });
    @export(&rwlockInitFace, .{ .name = "janet_os_rwlock_init" });
    @export(&rwlockDeinitFace, .{ .name = "janet_os_rwlock_deinit" });
    @export(&rwlockRlockFace, .{ .name = "janet_os_rwlock_rlock" });
    @export(&rwlockWlockFace, .{ .name = "janet_os_rwlock_wlock" });
    @export(&rwlockRunlockFace, .{ .name = "janet_os_rwlock_runlock" });
    @export(&rwlockWunlockFace, .{ .name = "janet_os_rwlock_wunlock" });
}

fn mutexSizeFace() callconv(.c) usize {
    return mutexSize();
}
fn rwlockSizeFace() callconv(.c) usize {
    return rwlockSize();
}
fn mutexInitFace(m: *anyopaque) callconv(.c) void {
    mutexInit(m);
}
fn mutexDeinitFace(m: *anyopaque) callconv(.c) void {
    mutexDeinit(m);
}
fn mutexLockFace(m: *anyopaque) callconv(.c) void {
    mutexLock(m);
}
fn mutexUnlockFace(m: *anyopaque) callconv(.c) void {
    raise.reported(mutexUnlock(m));
}
fn rwlockInitFace(r: *anyopaque) callconv(.c) void {
    rwlockInit(r);
}
fn rwlockDeinitFace(r: *anyopaque) callconv(.c) void {
    rwlockDeinit(r);
}
fn rwlockRlockFace(r: *anyopaque) callconv(.c) void {
    rwlockRlock(r);
}
fn rwlockWlockFace(r: *anyopaque) callconv(.c) void {
    rwlockWlock(r);
}
fn rwlockRunlockFace(r: *anyopaque) callconv(.c) void {
    rwlockRunlock(r);
}
fn rwlockWunlockFace(r: *anyopaque) callconv(.c) void {
    rwlockWunlock(r);
}
