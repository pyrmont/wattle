//! The three standard streams, named the way each libc names them.
//!
//! They are here because `stderr` is a macro, and the translation renders it a
//! different way on each of this project's platforms: an inline function on
//! macOS, a variable of opaque type on musl that Zig will not let a
//! many-pointer address, and on mingw a container-level constant whose
//! initializer calls an extern function, which Zig rejects outright as
//! "comptime call of extern function". The mingw case cannot be worked around
//! at a call site at all, because naming it is a compile error there whatever
//! is done with the result.
//!
//! All three of those are facts about the translation rather than about the
//! symbols. Underneath the macro every one of these libcs has an ordinary
//! extern object or function, so the fix is to stop asking `translate-c`
//! and name the symbol.
//!
//! | platform | what the macro expands to |
//! | --- | --- |
//! | Darwin and the BSDs | `c.__stdinp`, `c.__stdoutp`, `c.__stderrp` |
//! | glibc and musl | `c.stdin`, `c.stdout`, `c.stderr` |
//! | mingw / UCRT | `c.__acrt_iob_func(0 .. 2)` |
//!
//! Each returns a `*host.FILE` rather than an `?*anyopaque`, which is what the
//! `cabi` declarations underneath have to be while the six spellings differ.
//! The three streams are set up before `main` runs and libc offers no way to
//! clear one, so the unwrap here is where that fact is stated, rather than a
//! null check at every caller.

// ==========================================================================
// Standard library imports
// ==========================================================================

const builtin = @import("builtin");

// ==========================================================================
// Project imports
// ==========================================================================

const c = @import("cabi");
const host = @import("host");

// ==========================================================================
// Constants
// ==========================================================================

/// Whether this target's libc names the streams the Darwin and BSD way.
const darwin_or_bsd = switch (builtin.os.tag) {
    .macos, .ios, .tvos, .watchos, .visionos, .driverkit => true,
    .freebsd, .netbsd, .openbsd, .dragonfly => true,
    else => false,
};

/// The three standard streams, each as the platform's own symbol. `impl`
/// selects the arm and these are the names the rest of the tree calls.
pub const err = impl.err;
pub const in = impl.in;
pub const out = impl.out;

// ==========================================================================
// Types
// ==========================================================================

/// The arm this target's libc needs, selected at comptime.
///
/// Each arm declares `in`, `out` and `err` over the symbols that platform
/// actually exports, so the three constants above are one load either way.
const impl = if (builtin.os.tag == .windows) struct {
    // The UCRT has no exported `c.stdin`. The macro calls this and indexes the
    // `_iob` table, so the index is the interface.
    pub fn in() *host.FILE {
        return c.__acrt_iob_func(0).?;
    }
    pub fn out() *host.FILE {
        return c.__acrt_iob_func(1).?;
    }
    pub fn err() *host.FILE {
        return c.__acrt_iob_func(2).?;
    }
} else if (darwin_or_bsd) struct {
    pub fn in() *host.FILE {
        return c.__stdinp.?;
    }
    pub fn out() *host.FILE {
        return c.__stdoutp.?;
    }
    pub fn err() *host.FILE {
        return c.__stderrp.?;
    }
} else struct {
    // musl spells these `FILE *const` and glibc `FILE *`; the difference is in
    // the declaration rather than in the object, and reading one is the same
    // load either way.
    pub fn in() *host.FILE {
        return c.stdin.?;
    }
    pub fn out() *host.FILE {
        return c.stdout.?;
    }
    pub fn err() *host.FILE {
        return c.stderr.?;
    }
};
