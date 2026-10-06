//! The recursive mutex and the reader/writer lock `ev/lock` and `ev/rwlock`
//! are made of, and the channel's own lock.
//!
//! Both are written in Zig on every platform, over `std.Io.Mutex` and
//! `std.Io.Condition`. Each is a value the caller allocates and passes by
//! pointer: `ev/lock` and `ev/rwlock` allocate `mutexSize()` and
//! `rwlockSize()` bytes as an abstract's payload, and a channel embeds a
//! `Mutex`.
//!
//! - The mutex is recursive. A thread that holds it may take it again, which
//!   `ev/with-lock` relies on when a function that has taken a lock calls
//!   another that takes the same one. Releasing it from a thread that does not
//!   hold it raises.
//!
//! - The reader/writer lock admits any number of readers or one writer.
//!   Releasing it when it is not held in that mode does nothing.
//!
//! - Every wait goes through one `std.Io.Threaded` instance, `io_instance`
//!   below, which the runtime owns. Its futex calls are the operating
//!   system's (`futex`, `os_sync_wait_on_address`, `_umtx_op`,
//!   `RtlWaitOnAddress`) and use nothing else of the instance.
//!
//! All twelve entry points are reached by import. `mutexUnlock` is the only
//! one that can fail, and it returns its raise like everything else here.

// ==========================================================================
// Standard library imports
// ==========================================================================

const std = @import("std");

// ==========================================================================
// Project imports
// ==========================================================================

const raise = @import("../../api/raise.zig");

// ==========================================================================
// Constants
// ==========================================================================

/// The `std.Io` instance every wait in this file goes through.
var io_instance: std.Io.Threaded = .init_single_threaded;

/// The thread id that no thread has, which an unheld mutex records as its
/// owner.
const no_owner: std.Thread.Id = 0;

// ==========================================================================
// Types
// ==========================================================================

/// A recursive mutex.
///
/// `owner` is the id of the thread that holds it, or `no_owner`, and `depth`
/// is how many times that thread has taken it. Only the holder writes either,
/// so `depth` needs no atomic access; `owner` is atomic because another thread
/// reads it to learn that it is not the holder.
pub const Mutex = struct {
    inner: std.Io.Mutex = .init,
    owner: std.atomic.Value(std.Thread.Id) = .init(no_owner),
    depth: u32 = 0,
};

/// A reader/writer lock.
///
/// `readers` is how many readers hold it and `writer` whether a writer does.
/// Both are read and written only with `inner` held, and `changed` is
/// broadcast whenever a release makes room.
pub const RwLock = struct {
    inner: std.Io.Mutex = .init,
    changed: std.Io.Condition = .init,
    readers: u32 = 0,
    writer: bool = false,
};

// ==========================================================================
// Public functions
// ==========================================================================

/// Destroys a mutex. A `Mutex` holds no resource, so this does nothing.
pub fn mutexDeinit(mutex: *anyopaque) void {
    _ = mutex;
}

/// Initialises a mutex.
pub fn mutexInit(mutex: *anyopaque) void {
    asMutex(mutex).* = .{};
}

/// Takes a mutex, blocking until it is free or this thread holds it.
pub fn mutexLock(mutex: *anyopaque) void {
    const m = asMutex(mutex);
    const self = std.Thread.getCurrentId();
    if (m.owner.load(.monotonic) == self) {
        m.depth += 1;
        return;
    }
    m.inner.lockUncancelable(io());
    m.owner.store(self, .monotonic);
    m.depth = 1;
}

/// What the caller must allocate for a mutex. `ev/lock` hands this to
/// `abstracts.threaded`, so it is the abstract's payload size.
pub fn mutexSize() usize {
    return @sizeOf(Mutex);
}

/// Releases a mutex once.
///
/// This function raises if the calling thread does not hold the mutex.
pub fn mutexUnlock(mutex: *anyopaque) raise.Error!void {
    const m = asMutex(mutex);
    if (m.owner.load(.monotonic) != std.Thread.getCurrentId())
        return raise.panic("cannot release lock");
    m.depth -= 1;
    if (m.depth != 0) return;
    m.owner.store(no_owner, .monotonic);
    m.inner.unlock(io());
}

/// Destroys a reader/writer lock. An `RwLock` holds no resource, so this does
/// nothing.
pub fn rwlockDeinit(rwlock: *anyopaque) void {
    _ = rwlock;
}

/// Initialises a reader/writer lock.
pub fn rwlockInit(rwlock: *anyopaque) void {
    asRwLock(rwlock).* = .{};
}

/// Takes a reader/writer lock for reading, blocking while a writer holds it.
pub fn rwlockRlock(rwlock: *anyopaque) void {
    const l = asRwLock(rwlock);
    l.inner.lockUncancelable(io());
    defer l.inner.unlock(io());
    while (l.writer) l.changed.waitUncancelable(io(), &l.inner);
    l.readers += 1;
}

/// Releases a lock taken for reading. Releasing a lock no reader holds does
/// nothing.
pub fn rwlockRunlock(rwlock: *anyopaque) void {
    const l = asRwLock(rwlock);
    l.inner.lockUncancelable(io());
    defer l.inner.unlock(io());
    if (l.readers == 0) return;
    l.readers -= 1;
    if (l.readers == 0) l.changed.broadcast(io());
}

/// What the caller must allocate for a reader/writer lock.
pub fn rwlockSize() usize {
    return @sizeOf(RwLock);
}

/// Takes a reader/writer lock for writing, blocking while a reader or another
/// writer holds it.
pub fn rwlockWlock(rwlock: *anyopaque) void {
    const l = asRwLock(rwlock);
    l.inner.lockUncancelable(io());
    defer l.inner.unlock(io());
    while (l.writer or l.readers != 0) l.changed.waitUncancelable(io(), &l.inner);
    l.writer = true;
}

/// Releases a lock taken for writing. Releasing a lock no writer holds does
/// nothing.
pub fn rwlockWunlock(rwlock: *anyopaque) void {
    const l = asRwLock(rwlock);
    l.inner.lockUncancelable(io());
    defer l.inner.unlock(io());
    if (!l.writer) return;
    l.writer = false;
    l.changed.broadcast(io());
}

// ==========================================================================
// Private functions
// ==========================================================================

/// Views a caller's allocation as a `Mutex`.
inline fn asMutex(mutex: *anyopaque) *Mutex {
    return @ptrCast(@alignCast(mutex));
}

/// Views a caller's allocation as an `RwLock`.
inline fn asRwLock(rwlock: *anyopaque) *RwLock {
    return @ptrCast(@alignCast(rwlock));
}

/// The `std.Io` interface of `io_instance`.
inline fn io() std.Io {
    return io_instance.io();
}
