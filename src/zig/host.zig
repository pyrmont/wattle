//! The shapes the host decides, which every compilation must spell the same
//! way.
//!
//! A descriptor, a `FILE`, a pthread handle and its attributes, a mutex: none
//! of these is Janet's, and none of them can be derived. What each is is fixed
//! by the platform and its libc, so the one thing that matters is that every
//! file naming one names *this* declaration -- two spellings of
//! `pthread_attr_t` in one program is a silent offset mismatch, not a compile
//! error.
//!
//! **Only the host's own shapes are here.** Every value and runtime type lives
//! with the file that owns what is done to it -- `DESIGN.md` section 14 --
//! `fibers.Fiber`, `tables.Table`, `functions.FuncDef`, `ev_stream.Stream`.
//! These six cannot, and the reason is the one `DESIGN.md` section 14 gives for
//! `abi.zig`: **two modules must agree on them.** `cabi.zig` declares
//! `pthread_create`, `pthread_join`, `fdopen` and the Win32 handle calls, and
//! it is a separate module because its `@cImport` needs the C include path; a
//! file of `root` cannot be imported by it. So this is a module, like `abi` and
//! for the same reason -- not a catalogue, and not a residue.

const std = @import("std");
const builtin = @import("builtin");

pub const FILE = std.c.FILE;

/// The pthread types, from libc rather than from `std.c`.
///
/// **`std.c` is wrong for musl and it would not have shown up here.** It
/// carries glibc's `pthread_attr_t` -- 56 bytes of storage plus a `c_long` of
/// alignment -- where musl's is 56 bytes total on 64-bit and 36 on 32-bit.
/// `Vm` embeds one, so taking `std.c`'s would move every field after
/// `new_thread_attr` on every Linux target while remaining correct on macOS.
/// It was caught as `size 56 vs 64` and `36 vs 60`, and only because the
/// cross-compile targets run.
///
/// Reaching libc through `@cImport` is deliberate: "no C in the tree" and "no
/// libc" are different claims, and only the first is a goal. What matters is
/// that the size comes from the platform rather than from a table someone
/// maintains by hand.
///
/// Nothing crosses a translation boundary by value. `ev.zig` declares
/// `pthread_attr_init` and its neighbours itself, taking a pointer, so these
/// types are storage and an address and nothing more.
const libc = if (builtin.os.tag == .windows) struct {
    // No pthreads. `Vm`'s Windows arm has no `new_thread_attr` field, so
    // nothing below is instantiated -- but both names still have to resolve.
    pub const pthread_attr_t = extern struct {};
    pub const pthread_t = ?*anyopaque;
    pub const pthread_mutex_t = extern struct {};
} else @cImport({
    @cInclude("pthread.h");
});

pub const pthread_attr_t = libc.pthread_attr_t;
pub const pthread_t = libc.pthread_t;
pub const pthread_mutex_t = libc.pthread_mutex_t;

/// Windows' mutex, which `ev/channel.zig` selects instead of a
/// `pthread_mutex_t`. From `std.os.windows` rather than from a `@cImport`,
/// because there is one Windows ABI -- the per-libc caveat that made
/// `std.pthread_attr_t` wrong does not have an analogue here. `void` off
/// Windows, where the branch selecting it is comptime-false.
pub const CRITICAL_SECTION = if (builtin.os.tag == .windows)
    std.os.windows.CRITICAL_SECTION
else
    void;

/// A file or socket descriptor. Windows hands back a `HANDLE`.
pub const Handle = if (builtin.os.tag == .windows) ?*anyopaque else c_int;
