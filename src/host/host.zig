//! The shapes the host decides, which every compilation must spell the same
//! way.
//!
//! A descriptor, a `FILE`, a pthread handle: none of these is Janet's, and
//! none can be derived. What each is is fixed by the platform and its libc, so
//! what matters is that every file naming such a shape names this
//! declaration.
//!
//! `build.zig` roots a module at this file, so `host` is a module rather than
//! a file of the runtime. `cabi.zig` is a module too, because the client, the
//! contract driver and the test executables import it as well as `root`.
//!
//! This file is an authoritative Zig source, and so are `api/constants.zig`
//! and `api/repr.zig`. Each shape here comes from `std`, as
//! `src/README.md`'s Overview requires of a host declaration.
//!
//! Only the host's own shapes are here. Every value and runtime type lives
//! with the file that owns what is done to it: `value/fibers.zig`'s `Fiber`,
//! `value/tables.zig`'s `Table`, `value/functions.zig`'s `FuncDef`,
//! `ev/stream.zig`'s `Stream`. These six cannot, for the reason `abi.zig`'s
//! declarations cannot: two modules must agree on them.

// ==========================================================================
// Standard library imports
// ==========================================================================

const std = @import("std");
const builtin = @import("builtin");

// ==========================================================================
// Aliased types
// ==========================================================================

/// A libc `FILE`, from `std.c`. `cabi.zig`'s stream calls take a `?*FILE`,
/// and `runtime/io.zig` names it and reads no field of it.
pub const FILE = std.c.FILE;

/// A thread handle: `std.c.pthread_t`, and a Windows thread `HANDLE`, which
/// `runtime/ev.zig`'s deadline worker keeps in the same field.
pub const pthread_t = if (builtin.target.os.tag == .windows) ?*anyopaque else std.c.pthread_t;

// ==========================================================================
// Types
// ==========================================================================

/// A file or socket descriptor. Windows gives back a `HANDLE`, so the type is
/// a pointer there and a `c_int` everywhere else.
pub const Handle = if (builtin.target.os.tag == .windows) ?*anyopaque else c_int;

/// Where the three pthread types above come from.
///
/// Off Windows this is `build.zig`'s translation of `pthread.h` for the target,
/// so each size is the platform's. On Windows there are no pthreads, and the arm declares the
/// three names anyway, two as empty structs and `pthread_t` as an opaque
/// pointer, because all three still have to resolve.
const libc = if (builtin.target.os.tag == .windows) struct {
    // `VmBackend`'s Windows arm has no `new_thread_attr` field, so nothing
    // here is instantiated.
    pub const pthread_attr_t = extern struct {};
    pub const pthread_t = ?*anyopaque;
    pub const pthread_mutex_t = extern struct {};
} else @import("c_pthread");
