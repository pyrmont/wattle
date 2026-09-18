//! The recursive mutex and the reader/writer lock `ev/lock` and `ev/rwlock`
//! are made of, and the channel's own lock.
//!
//! `pthread_mutex_t`, `pthread_rwlock_t`, `pthread_mutexattr_t` and
//! `PTHREAD_MUTEX_RECURSIVE` come from `host.zig`, for the reason it gives;
//! the Windows arm is four `kernel32` calls with no structure to lay out
//! beyond `CRITICAL_SECTION`. `CRITICAL_SECTION` is a structure and an
//! `SRWLOCK` is a single pointer, and both come from `std.os.windows` rather
//! than from a second translation of `<windows.h>`, which is what
//! `os/abi.h`'s note asks for.
//!
//! The mutex is recursive on purpose. `PTHREAD_MUTEX_RECURSIVE` is what lets a
//! Janet function that has taken a lock call another that takes the same one,
//! which `ev/with-lock` relies on. A default mutex deadlocks there instead,
//! and nothing in the suites would say so.
//!
//! All twelve entry points are reached by import. `mutexUnlock` is the only
//! one that can fail, and it returns its raise like everything else here.

// ==========================================================================
// Standard library imports
// ==========================================================================

const builtin = @import("builtin");

// ==========================================================================
// Project imports
// ==========================================================================

const c = @import("cabi");
const raise = @import("../../api/raise.zig");

/// A translation of `<pthread.h>` alone, and one of seven in the tree.
///
/// `host.zig` takes only the three types `Vm` embeds, and this file needs the
/// mutex calls as well.
///
/// A translation is right when nothing it declares crosses a subsystem
/// boundary, and nothing does. Every caller passes an opaque mutex pointer;
/// the `pthread_*` types stay inside this file. The Windows arm is an empty
/// struct, because that platform's four calls are `kernel32`'s.
const sys = if (windows) struct {} else @cImport({
    @cInclude("wattle_features.h");
    @cInclude("pthread.h");
});

// ==========================================================================
// Constants
// ==========================================================================

/// Whether this target takes the `kernel32` arm of each call below.
const windows = builtin.os.tag == .windows;

// ==========================================================================
// Public functions
// ==========================================================================

/// Destroys a mutex.
pub fn mutexDeinit(mutex: *anyopaque) void {
    if (windows) {
        c.DeleteCriticalSection(@ptrCast(@alignCast(mutex)));
    } else {
        _ = sys.pthread_mutex_destroy(@ptrCast(@alignCast(mutex)));
    }
}

/// Initialises a mutex, recursive on POSIX.
pub fn mutexInit(mutex: *anyopaque) void {
    if (windows) {
        c.InitializeCriticalSection(@ptrCast(@alignCast(mutex)));
    } else {
        var attr: sys.pthread_mutexattr_t = undefined;
        _ = sys.pthread_mutexattr_init(&attr);
        _ = sys.pthread_mutexattr_settype(&attr, sys.PTHREAD_MUTEX_RECURSIVE);
        _ = sys.pthread_mutex_init(@ptrCast(@alignCast(mutex)), &attr);
    }
}

/// Takes a mutex, blocking until it is free.
pub fn mutexLock(mutex: *anyopaque) void {
    if (windows) {
        c.EnterCriticalSection(@ptrCast(@alignCast(mutex)));
    } else {
        _ = sys.pthread_mutex_lock(@ptrCast(@alignCast(mutex)));
    }
}

/// What the caller must allocate for a mutex. `ev/lock` hands this to
/// `abstracts.threaded`, so it is the abstract's payload size.
pub fn mutexSize() usize {
    return if (windows) @sizeOf(c.CriticalSection) else @sizeOf(sys.pthread_mutex_t);
}

/// Releases a mutex, which is the one of the twelve that can fail, and it
/// raises by returning.
///
/// The Windows arm cannot fail and so cannot report:
/// `c.LeaveCriticalSection` returns `void`, since Win32 gives a
/// critical-section release no failure to observe, where
/// `pthread_mutex_unlock` reports an `errno`. The asymmetry is the platform's,
/// and the raising return type is what the POSIX arm needs.
pub fn mutexUnlock(mutex: *anyopaque) raise.Error!void {
    if (windows) {
        c.LeaveCriticalSection(@ptrCast(@alignCast(mutex)));
    } else {
        if (sys.pthread_mutex_unlock(@ptrCast(@alignCast(mutex))) != 0)
            return raise.panic("cannot release lock");
    }
}

/// A no-op on Windows, as it is in the C: an `SRWLOCK` owns nothing to
/// release. The C says "no op?" with the question mark; it is not a question,
/// and the entry point exists so that the two platforms have the same shape.
pub fn rwlockDeinit(rwlock: *anyopaque) void {
    if (windows) return;
    _ = sys.pthread_rwlock_destroy(@ptrCast(@alignCast(rwlock)));
}

/// Initialises a reader/writer lock.
pub fn rwlockInit(rwlock: *anyopaque) void {
    if (windows) {
        c.InitializeSRWLock(@ptrCast(@alignCast(rwlock)));
    } else {
        _ = sys.pthread_rwlock_init(@ptrCast(@alignCast(rwlock)), null);
    }
}

/// Takes a reader/writer lock for reading.
pub fn rwlockRlock(rwlock: *anyopaque) void {
    if (windows) {
        c.AcquireSRWLockShared(@ptrCast(@alignCast(rwlock)));
    } else {
        _ = sys.pthread_rwlock_rdlock(@ptrCast(@alignCast(rwlock)));
    }
}

/// Releases a lock taken for reading. Windows needs two release calls where
/// POSIX has one, because an `SRWLOCK` does not record which way it was taken.
pub fn rwlockRunlock(rwlock: *anyopaque) void {
    if (windows) {
        c.ReleaseSRWLockShared(@ptrCast(@alignCast(rwlock)));
    } else {
        _ = sys.pthread_rwlock_unlock(@ptrCast(@alignCast(rwlock)));
    }
}

/// What the caller must allocate for a reader/writer lock.
pub fn rwlockSize() usize {
    return if (windows) @sizeOf(c.SrwLock) else @sizeOf(sys.pthread_rwlock_t);
}

/// Takes a reader/writer lock for writing.
pub fn rwlockWlock(rwlock: *anyopaque) void {
    if (windows) {
        c.AcquireSRWLockExclusive(@ptrCast(@alignCast(rwlock)));
    } else {
        _ = sys.pthread_rwlock_wrlock(@ptrCast(@alignCast(rwlock)));
    }
}

/// Releases a lock taken for writing.
pub fn rwlockWunlock(rwlock: *anyopaque) void {
    if (windows) {
        c.ReleaseSRWLockExclusive(@ptrCast(@alignCast(rwlock)));
    } else {
        _ = sys.pthread_rwlock_unlock(@ptrCast(@alignCast(rwlock)));
    }
}
