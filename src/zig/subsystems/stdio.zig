//! The three standard streams, named the way each libc names them.
//!
//! `io.c` kept a one-line accessor for each of these for four increments,
//! and its comment gave the reason: `stderr` is a *macro*, and
//! `translate-c` renders it a different way on each of this project's
//! platforms — an inline function on macOS, a variable of opaque type on musl,
//! which Zig will not let a many-pointer address, and on mingw a
//! container-level constant whose initializer calls an extern function, which
//! Zig rejects outright as "comptime call of extern function". The third could
//! not be worked around at the call site at all: naming `c.stderr` is a compile
//! error there whatever is done with the result.
//!
//! All three of those are facts about the *translation*, not about the symbols.
//! Underneath the macro every one of these libcs has an ordinary extern object
//! or function, and Phase 10's rule 3 is the one that applies — a host
//! structure stays in C only when translate-c cannot give it to us, and the
//! answer here is to stop asking translate-c and name the symbol.
//!
//! | platform | what the macro expands to |
//! | --- | --- |
//! | Darwin and the BSDs | `__stdinp`, `__stdoutp`, `__stderrp` |
//! | glibc and musl | `stdin`, `stdout`, `stderr` |
//! | mingw / UCRT | `__acrt_iob_func(0 .. 2)` |
//!
//! Verified by compiling for all six targets this project builds for and by
//! writing through the resulting handle on the host. The pointer is
//! `?*anyopaque` rather than a `FILE *`: `io_core.zig` declares `FILE` opaque
//! on purpose, `@cImport`'s translation is a fourth spelling again, and every
//! consumer of these either passes the handle straight back to libc or casts it
//! once. They are the same pointer and not the same Zig type.

const builtin = @import("builtin");

const darwin_or_bsd = switch (builtin.os.tag) {
    .macos, .ios, .tvos, .watchos, .visionos, .driverkit => true,
    .freebsd, .netbsd, .openbsd, .dragonfly => true,
    else => false,
};

const impl = if (builtin.os.tag == .windows) struct {
    // The UCRT has no exported `stdin`; the macro calls this and indexes the
    // `_iob` table, so the index *is* the interface.
    extern fn __acrt_iob_func(index: c_uint) callconv(.c) ?*anyopaque;
    pub fn in() ?*anyopaque {
        return __acrt_iob_func(0);
    }
    pub fn out() ?*anyopaque {
        return __acrt_iob_func(1);
    }
    pub fn err() ?*anyopaque {
        return __acrt_iob_func(2);
    }
} else if (darwin_or_bsd) struct {
    extern var __stdinp: ?*anyopaque;
    extern var __stdoutp: ?*anyopaque;
    extern var __stderrp: ?*anyopaque;
    pub fn in() ?*anyopaque {
        return __stdinp;
    }
    pub fn out() ?*anyopaque {
        return __stdoutp;
    }
    pub fn err() ?*anyopaque {
        return __stderrp;
    }
} else struct {
    // musl spells these `FILE *const` and glibc `FILE *`; the difference is in
    // the declaration rather than in the object, and reading one is the same
    // load either way.
    extern var stdin: ?*anyopaque;
    extern var stdout: ?*anyopaque;
    extern var stderr: ?*anyopaque;
    pub fn in() ?*anyopaque {
        return stdin;
    }
    pub fn out() ?*anyopaque {
        return stdout;
    }
    pub fn err() ?*anyopaque {
        return stderr;
    }
};

pub const in = impl.in;
pub const out = impl.out;
pub const err = impl.err;
