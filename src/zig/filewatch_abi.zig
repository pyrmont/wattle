//! The single translation of the host headers `filewatch.c`'s backends worked
//! through.
//!
//! `filewatch_abi.h` carries the reasoning, including why this is a fourth
//! translation rather than three includes added to `abi.zig`. What is here
//! beyond the translation is the handful of spellings `filewatch.c` made with
//! the preprocessor, and which a translation therefore cannot carry: the
//! backend selection as an enumeration, `EV_SET`, `S_ISDIR`, and the two
//! Windows declarations that live in `src/core/util.h` rather than in a system
//! header.

const std = @import("std");
const builtin = @import("builtin");

pub const h = @cImport({
    @cInclude("filewatch_abi.h");
});

/// Which of `filewatch.c`'s four implementations this target compiles. The
/// chain is in `filewatch_abi.h` and is the C file's exactly, `none` included:
/// a platform with no backend gets an implementation whose every entry point
/// raises "filewatch not supported on this platform".
pub const Backend = enum { none, inotify, windows, kqueue };

pub const backend: Backend = switch (h.JANET_ZIG_WATCH_BACKEND) {
    h.JANET_ZIG_WATCH_INOTIFY => .inotify,
    h.JANET_ZIG_WATCH_WINDOWS => .windows,
    h.JANET_ZIG_WATCH_KQUEUE => .kqueue,
    else => .none,
};

// ==========================================================================
// POSIX spellings that are macros
// ==========================================================================

/// `S_ISDIR`. A function-like macro, which translate-c renders as a
/// `@compileError` often enough that `net_abi.zig` met the same thing in
/// `_IOW`. The expansion is one mask and one comparison and both operands are
/// ordinary integer constants, so writing it out costs nothing and cannot be
/// demoted.
pub inline fn isDir(mode: anytype) bool {
    return (@as(u32, @intCast(mode)) & @as(u32, h.S_IFMT)) == @as(u32, h.S_IFDIR);
}

/// `EV_SETx`, which `filewatch.c` defines over `EV_SET` only to cast `udata`
/// to whatever the host declared it as. Every watch this file registers passes
/// a null `udata`, so the cast the macro exists for has nothing to do.
///
/// Written as a mutation of a zeroed structure rather than as a struct literal
/// because `struct kevent` is not the same shape on every BSD -- FreeBSD adds
/// four `ext` words -- and `filewatch.c` zeroes it first for the same reason.
pub fn evSetVnode(kev: *h.struct_kevent, fd: c_int, flags: u32) void {
    kev.* = std.mem.zeroes(h.struct_kevent);
    kev.ident = @intCast(fd);
    kev.filter = @intCast(h.EVFILT_VNODE);
    kev.flags = @intCast(h.EV_ADD | h.EV_ENABLE | h.EV_CLEAR);
    kev.fflags = @intCast(flags);
}

// ==========================================================================
// Two Windows declarations that are not in a system header
// ==========================================================================

/// `OVERLAPPED`, restated for the reason `net_sockets.zig` and
/// `ev_stream.zig` restate it: it reaches this file through
/// `src/core/util.h`'s `JanetOverlapped`, `abi.zig` deliberately does not
/// translate that header, and Zig 0.16's `std.os.windows` no longer declares
/// `OVERLAPPED` at all.
pub const OVERLAPPED = extern struct {
    Internal: usize,
    InternalHigh: usize,
    Offset: u32,
    OffsetHigh: u32,
    hEvent: ?*anyopaque,
};

/// `JanetOverlapped` from `src/core/util.h`. The C original spells the first
/// member as a union of `OVERLAPPED` and `WSAOVERLAPPED`, which have the same
/// layout, so one arm is enough.
pub const JanetOverlapped = extern struct {
    as: OVERLAPPED,
    bytes_transfered: u32,
};

/// `INVALID_HANDLE_VALUE`. The macro is a cast of -1 to a pointer, which
/// translate-c renders inconsistently across the mingw headers; the value is
/// documented and fixed.
pub const invalid_handle_value: ?*anyopaque = @ptrFromInt(std.math.maxInt(usize));
