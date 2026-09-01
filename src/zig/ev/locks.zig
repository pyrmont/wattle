//! The recursive mutex and the reader/writer lock `ev/lock` and `ev/rwlock`
//! are made of, and the channel's own lock.
//!
//! `pthread_mutex_t`, `pthread_rwlock_t`, `pthread_mutexattr_t` and
//! `PTHREAD_MUTEX_RECURSIVE` come from `host.zig`, for the reason it gives; the
//! Windows arm is four `kernel32` calls with no structure to lay out beyond
//! `CRITICAL_SECTION`.
//!
//! **The mutex is recursive on purpose.** `PTHREAD_MUTEX_RECURSIVE` is what
//! lets a Janet function holding a lock call another that takes the same one,
//! which `ev/with-lock` relies on. A default mutex deadlocks there instead,
//! and nothing in the suites would say so.
//!
//! `janet_os_mutex_unlock` was the **last `janet_panic` call site compiled
//! into C**. It is a returned raise now, like everything else.

const builtin = @import("builtin");
const raise = @import("../raise.zig");
const c = @import("cabi");

const windows = builtin.os.tag == .windows;

/// A translation of `<pthread.h>` alone, and one of seven in the tree.
///
/// `types.zig` takes only the three types `Vm` embeds, and this file needs the
/// mutex calls as well.
///
/// A translation is right when nothing it declares crosses a subsystem
/// boundary, and nothing does. Every caller passes a `JanetOSMutex *`, which
/// Janet declares opaque; the `pthread_*` types stay inside this file.
const sys = if (windows) struct {} else @cImport({
    @cInclude("janet_features.h");
    @cInclude("pthread.h");
});

// `CRITICAL_SECTION` is a structure and an `SRWLOCK` is a single pointer; both
// come from `std.os.windows` rather than from a second translation of
// `<windows.h>`, which is what `os/abi.h`'s note asks for.

// ------------------------------------------------------------------ sizes

/// What the caller must allocate. `ev/lock` hands this to
/// `janet_abstract_threaded`, so it is the abstract's payload size.
pub fn mutexSize() usize {
    return if (windows) @sizeOf(c.CriticalSection) else @sizeOf(sys.pthread_mutex_t);
}

pub fn rwlockSize() usize {
    return if (windows) @sizeOf(c.SrwLock) else @sizeOf(sys.pthread_rwlock_t);
}

// ------------------------------------------------------------------ mutex

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

pub fn mutexDeinit(mutex: *anyopaque) void {
    if (windows) {
        c.DeleteCriticalSection(@ptrCast(@alignCast(mutex)));
    } else {
        _ = sys.pthread_mutex_destroy(@ptrCast(@alignCast(mutex)));
    }
}

pub fn mutexLock(mutex: *anyopaque) void {
    if (windows) {
        c.EnterCriticalSection(@ptrCast(@alignCast(mutex)));
    } else {
        _ = sys.pthread_mutex_lock(@ptrCast(@alignCast(mutex)));
    }
}

/// Unlocking is the one of the twelve that can fail, and the C original
/// panicked. It raises by returning now, which is what took the last
/// `janet_panic` call site out of C.
///
/// The Windows arm cannot report: `c.LeaveCriticalSection` returns `void`, and
/// the C original's comment -- "error handling? May want to keep counter" --
/// records that the author knew. Reproduced rather than repaired; `FOUND.md`
/// has the asymmetry.
pub fn mutexUnlock(mutex: *anyopaque) raise.Raising(void) {
    if (windows) {
        c.LeaveCriticalSection(@ptrCast(@alignCast(mutex)));
    } else {
        if (sys.pthread_mutex_unlock(@ptrCast(@alignCast(mutex))) != 0)
            return raise.panic("cannot release lock");
    }
}

// ----------------------------------------------------------------- rwlock

pub fn rwlockInit(rwlock: *anyopaque) void {
    if (windows) {
        c.InitializeSRWLock(@ptrCast(@alignCast(rwlock)));
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
        c.AcquireSRWLockShared(@ptrCast(@alignCast(rwlock)));
    } else {
        _ = sys.pthread_rwlock_rdlock(@ptrCast(@alignCast(rwlock)));
    }
}

pub fn rwlockWlock(rwlock: *anyopaque) void {
    if (windows) {
        c.AcquireSRWLockExclusive(@ptrCast(@alignCast(rwlock)));
    } else {
        _ = sys.pthread_rwlock_wrlock(@ptrCast(@alignCast(rwlock)));
    }
}

/// Windows needs two release calls where POSIX has one, because an `SRWLOCK`
/// does not record which way it was taken.
pub fn rwlockRunlock(rwlock: *anyopaque) void {
    if (windows) {
        c.ReleaseSRWLockShared(@ptrCast(@alignCast(rwlock)));
    } else {
        _ = sys.pthread_rwlock_unlock(@ptrCast(@alignCast(rwlock)));
    }
}

pub fn rwlockWunlock(rwlock: *anyopaque) void {
    if (windows) {
        c.ReleaseSRWLockExclusive(@ptrCast(@alignCast(rwlock)));
    } else {
        _ = sys.pthread_rwlock_unlock(@ptrCast(@alignCast(rwlock)));
    }
}

// ---------------------------------------------------------------- exports

comptime {
    // Janet declares all twelve, so they keep their C names. Only
    // `janet_os_mutex_unlock` needs an abi: it is the one that can raise.
}

// The host calls this file makes directly. Each names a type this file
// declares, so it stays with the type rather than moving to `cabi.zig`.
