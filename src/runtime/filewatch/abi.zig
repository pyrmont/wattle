//! The single translation of the host headers the filewatch backends work
//! through.
//!
//! `filewatch/abi.h` has the reasoning, including why this subsystem
//! translates its own headers rather than sharing another subsystem's. What is
//! here beyond the translation is what a translation cannot bring across: the
//! backend selection as an enumeration, `EV_SET`, and the two Windows
//! declarations that are in no system header.
//!
//! The selection chain and `filewatch/abi.h`'s have to agree, and nothing but
//! the assertion at the foot of this file would say so. The header picks which
//! backend's system headers are included; this file picks which backend's Zig
//! is compiled. A disagreement is silent in one direction and loud in the
//! other: selecting `none` where the header included `<sys/inotify.h>`
//! compiles cleanly and ships a runtime whose every `filewatch` entry point
//! raises, because a comptime-false branch is never analysed. The other
//! direction is a missing declaration, which is a compile error naming its own
//! site. So the loud direction is left to the compiler and the silent one is
//! asserted. Reordering the chain, where Windows leads because Aro predefines
//! the Unix names for mingw too, is exactly the kind of edit whose mistake
//! compiles.

// ==========================================================================
// Standard library imports
// ==========================================================================

const std = @import("std");
const builtin = @import("builtin");

// ==========================================================================
// Project imports
// ==========================================================================

/// The translation itself. Every `h.`-qualified name below is one of its
/// declarations.
pub const h = @cImport({
    @cInclude("filewatch/abi.h");
});

// ==========================================================================
// Constants
// ==========================================================================

/// Which of the four implementations this target compiles. The chain is
/// `filewatch.c`'s exactly, `none` included: a platform with no backend gets
/// an implementation whose every entry point raises "filewatch not supported
/// on this platform".
pub const backend: Backend = switch (builtin.os.tag) {
    .windows => .windows,
    .linux => .inotify,
    .macos, .ios, .tvos, .watchos, .visionos => .kqueue,
    .freebsd, .netbsd, .openbsd, .dragonfly => .kqueue,
    else => .none,
};

/// `INVALID_HANDLE_VALUE`. The macro is a cast of -1 to a pointer, which
/// translate-c renders inconsistently across the mingw headers; the value is
/// documented and fixed.
pub const invalid_handle_value: ?*anyopaque = @ptrFromInt(std.math.maxInt(usize));

// ==========================================================================
// Types
// ==========================================================================

/// The four implementations a target can compile.
pub const Backend = enum { none, inotify, windows, kqueue };

/// `OVERLAPPED`, restated for the reason `net.zig` and `ev/stream.zig` restate
/// it: Zig 0.16's `std.os.windows` no longer declares it, and no system header
/// this file translates has it.
pub const OVERLAPPED = extern struct {
    Internal: usize,
    InternalHigh: usize,
    Offset: u32,
    OffsetHigh: u32,
    hEvent: ?*anyopaque,
};

/// An `OVERLAPPED` with the transfer count beside it, which is what an
/// asynchronous read or write on Windows needs. `WSAOVERLAPPED` has the same
/// layout, so one member serves the socket calls too.
pub const Overlapped = extern struct {
    as: OVERLAPPED,
    bytes_transfered: u32,
};

// ==========================================================================
// Public functions
// ==========================================================================

/// `EV_SETx`, which `filewatch.c` defines over `EV_SET` only to cast `udata`
/// to whatever the host declared it as. Every watch this subsystem registers
/// passes a null `udata`, so the cast the macro exists for has nothing to do.
///
/// Written as a mutation of a zeroed structure rather than as a struct literal
/// because `struct kevent` is not the same shape on every BSD, since FreeBSD
/// adds four `ext` words, and `filewatch.c` zeroes it first for the same
/// reason.
pub fn evSetVnode(kev: *h.struct_kevent, fd: c_int, flags: u32) void {
    kev.* = std.mem.zeroes(h.struct_kevent);
    kev.ident = @intCast(fd);
    kev.filter = @intCast(h.EVFILT_VNODE);
    kev.flags = @intCast(h.EV_ADD | h.EV_ENABLE | h.EV_CLEAR);
    kev.fflags = @intCast(flags);
}

// ==========================================================================
// Tests
// ==========================================================================

comptime {
    const from_header: Backend = switch (h.WATTLE_WATCH_BACKEND) {
        h.WATTLE_WATCH_INOTIFY => .inotify,
        h.WATTLE_WATCH_WINDOWS => .windows,
        h.WATTLE_WATCH_KQUEUE => .kqueue,
        else => .none,
    };
    if (from_header != backend) @compileError(
        "filewatch/abi.h selected " ++ @tagName(from_header) ++
            " and filewatch/abi.zig selected " ++ @tagName(backend),
    );
}
