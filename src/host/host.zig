//! The shapes the host decides, which every compilation must spell the same
//! way.
//!
//! A descriptor, a `FILE`, a pthread handle and its attributes, a mutex: none
//! of these is Janet's, and none can be derived. What each is is fixed by the
//! platform and its libc, so what matters is that every file naming such a
//! shape names this declaration. Two spellings of `pthread_attr_t` in one
//! program is a silent offset mismatch rather than a compile error.
//!
//! `build.zig` roots a module at this file, so `host` is a module rather than
//! a file of the runtime. `cabi.zig` is a module for the same reason: its
//! `@cImport` needs the C include path, and a file of `root` cannot be
//! imported by it.
//!
//! This file is an authoritative Zig source, and so are `api/constants.zig`
//! and `api/repr.zig`. Nothing translates a Janet header into any of the
//! three. Reaching libc through `@cImport` is deliberate: "no C in the tree"
//! and "no libc" are different claims and only the first is a goal, and what
//! matters is that a size comes from the platform rather than from a table
//! kept by hand.
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

/// The pthread types, from libc rather than from `std.c`.
///
/// `std.c` declares glibc's `pthread_attr_t`, and musl's has a different
/// size, so `std.c`'s is wrong on a musl target and correct on macOS.
/// `runtime/ev/backend.zig`'s `VmBackend` embeds a `pthread_attr_t` in
/// three of its four arms, and `vm/state.zig`'s `Vm` has a `VmBackend`, so
/// taking `std.c`'s would move every field after `new_thread_attr` on every
/// Linux target. The size has to come from the platform rather than from a
/// table kept by hand.
///
/// Nothing crosses a translation boundary by value. `cabi.zig` declares
/// `pthread_attr_init` and its neighbours, each taking a pointer, so these
/// three types are storage and an address and nothing more.
pub const pthread_attr_t = libc.pthread_attr_t;
pub const pthread_mutex_t = libc.pthread_mutex_t;
pub const pthread_t = libc.pthread_t;

// ==========================================================================
// Types
// ==========================================================================

/// Windows' mutex, which `runtime/ev/channel.zig` selects instead of a
/// `pthread_mutex_t`, and `void` off Windows where that selection is
/// comptime-false.
///
/// It comes from `std.os.windows` rather than from a `@cImport`, because there
/// is one Windows ABI: the per-libc difference that makes `std.c`'s
/// `pthread_attr_t` wrong has no analogue here.
pub const CRITICAL_SECTION = if (builtin.os.tag == .windows)
    std.os.windows.CRITICAL_SECTION
else
    void;

/// A file or socket descriptor. Windows gives back a `HANDLE`, so the type is
/// a pointer there and a `c_int` everywhere else.
pub const Handle = if (builtin.os.tag == .windows) ?*anyopaque else c_int;

/// Where the three pthread types above come from.
///
/// Off Windows this is `@cImport` of `pthread.h`, so each size is the
/// platform's. On Windows there are no pthreads, and the arm declares the
/// three names anyway, two as empty structs and `pthread_t` as an opaque
/// pointer, because all three still have to resolve.
const libc = if (builtin.os.tag == .windows) struct {
    // `VmBackend`'s Windows arm has no `new_thread_attr` field, so nothing
    // here is instantiated.
    pub const pthread_attr_t = extern struct {};
    pub const pthread_t = ?*anyopaque;
    pub const pthread_mutex_t = extern struct {};
} else @cImport({
    @cInclude("pthread.h");
});
