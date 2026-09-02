//! Loading a native module: a library handle and the four operations over it,
//! for POSIX, for Windows, and for a build with dynamic modules turned off.
//!
//! **The Win32 loader is the only one written out.** On POSIX the four are
//! `dlopen`, `dlsym`, `dlclose` and `dlerror` and there is nothing to write;
//! on Windows all four are real functions, below.
//!
//! ## Why `symbol` raises and the others do not
//!
//! Exactly one path here can fail in a way a Janet program should see:
//! `symbolClib`, asked for a symbol in the *process* rather than in a loaded
//! library, walks every loaded module and panics if `c.EnumProcessModules`
//! fails. Nothing else reports anything but a null pointer.
//!
//! So `symbol` returns `raise.Raising(?*anyopaque)` on every platform while
//! only the Windows arm can ever return the error. Declaring what you cannot
//! do yields where several implementations share a call site: one source line,
//! `try dynlib.symbol(...)`, cannot need a `try` on Windows and not on Linux.
//! `ev/backend.zig`'s four backends are the same shape.
//!
//! ## None of this is executed here
//!
//! macOS and Linux run the `dlopen` arm, and the Windows arm is compiled by
//! `x86_64-windows-gnu` and executed by nothing. What that buys is type
//! checking and no more, so the Windows arm below is written to be read
//! against upstream's line by line, and the one place it deliberately differs
//! says so.

const std = @import("std");
const builtin = @import("builtin");
const raise = @import("../api/raise.zig");
const pp_format = @import("pp/format.zig");
const config = @import("config");
const c = @import("cabi");

const windows = builtin.os.tag == .windows;
const has_dynamic_modules = config.dynamic_modules;

/// A loaded library. A `HINSTANCE` on Windows and a `void *` elsewhere, which
/// are the same width; `c_int` when the feature is off, so the stubs below have
/// something to return.
pub const Handle = if (has_dynamic_modules) ?*anyopaque else c_int;

pub fn load(name: ?[*:0]const u8) Handle {
    if (!has_dynamic_modules) return 0;
    if (windows) return loadClib(name);
    return std.c.dlopen(name, .{ .NOW = true });
}

/// Look a symbol up, in one library or across the whole process.
///
/// The error is declared on every platform and returned only on Windows; the
/// head of this file says why.
pub fn symbol(lib: Handle, sym: [*:0]const u8) raise.Raising(?*anyopaque) {
    if (!has_dynamic_modules) return null;
    if (windows) return symbolClib(lib, sym);
    return std.c.dlsym(lib, sym);
}

pub fn free(lib: Handle) void {
    if (!has_dynamic_modules) return;
    if (windows) return freeClib(lib);
    _ = std.c.dlclose(lib.?);
}

/// The last loader error as text.
///
/// `dlerror` answers null when nothing has failed, and both callers --
/// `ffi.zig`'s `raise.panic` and `env.zig`'s `strings.cstring` -- would walk
/// from address zero if it were handed on. It is unreachable through either,
/// each of which reaches this only on the branch a failed `dlopen` took. The
/// null arm is written out rather than left implicit, because Zig's type says
/// it can happen.
pub fn lastError() [*:0]const u8 {
    if (!has_dynamic_modules) return @ptrCast(errorClibUnsupported());
    if (windows) return @ptrCast(errorClib());
    return std.c.dlerror() orelse "unknown dynamic linker error";
}

pub fn failed(lib: Handle) bool {
    if (!has_dynamic_modules) return true;
    return lib == null;
}

// ==========================================================================
// The Win32 loader
// ==========================================================================

// With dynamic modules off, only the error string is real; the rest are stubs.

fn errorClibUnsupported() [*:0]const u8 {
    return "dynamic modules not supported";
}

/// `c.FormatMessageA`'s buffer, static so that the answer stays valid until
/// the next failure on any thread. That is a race, and nothing in the tree can
/// reach it twice.
var error_clib_buf: [256]u8 = @splat(0);

const FORMAT_MESSAGE_FROM_SYSTEM: u32 = 0x1000;
const FORMAT_MESSAGE_IGNORE_INSERTS: u32 = 0x200;

/// `MAKELANGID(LANG_NEUTRAL, SUBLANG_DEFAULT)`, which is
/// `(SUBLANG_DEFAULT << 10) | LANG_NEUTRAL` and therefore `0x400`. Written as
/// the arithmetic rather than the constant so it can be read against the macro.
const LANG_NEUTRAL_SUBLANG_DEFAULT: u32 = (1 << 10) | 0;

fn errorClib() [*:0]const u8 {
    const written = c.FormatMessageA(
        FORMAT_MESSAGE_FROM_SYSTEM | FORMAT_MESSAGE_IGNORE_INSERTS,
        null,
        c.GetLastError(),
        LANG_NEUTRAL_SUBLANG_DEFAULT,
        &error_clib_buf,
        error_clib_buf.len,
        null,
    );

    // The strip removes the newline `c.FormatMessageA` appends, and it is
    // guarded on both the call's success and the resulting length: writing the
    // terminator at `len - 1` unguarded indexes below the array when the call
    // writes nothing.
    const len = std.mem.len(@as([*:0]const u8, @ptrCast(&error_clib_buf)));
    if (written != 0 and len != 0) error_clib_buf[len - 1] = 0;

    return @ptrCast(&error_clib_buf);
}

/// A null name asks for the running process rather than for a library, and
/// `GetModuleHandle(NULL)` is how Win32 spells that. `free` and `symbol` both
/// test against it, which is why it is a handle rather than a flag.
fn loadClib(name: ?[*:0]const u8) ?*anyopaque {
    const path = name orelse return c.GetModuleHandleA(null);
    return c.LoadLibraryA(path);
}

fn freeClib(lib: ?*anyopaque) void {
    if (lib != c.GetModuleHandleA(null)) {
        _ = c.FreeLibrary(lib);
    }
}

/// A symbol in one library, or the first match across every module the process
/// has loaded.
///
/// The second case is what `(ffi/native)` with no path asks for. **The array
/// of 1024 module handles is a fixed limit and it is contract.**
/// `c.EnumProcessModules` reports how much it *wanted* in `needed`, and
/// nothing here grows the array or notices the truncation, so a process with
/// more than 1024 modules searches the first 1024 and says nothing. It is
/// defined behaviour, just a limit nobody documented.
fn symbolClib(lib: ?*anyopaque, sym: [*:0]const u8) raise.Raising(?*anyopaque) {
    if (lib != c.GetModuleHandleA(null)) {
        return c.GetProcAddress(lib, sym);
    }

    var modules: [1024]?*anyopaque = undefined;
    var needed: u32 = 0;
    if (c.EnumProcessModules(c.GetCurrentProcess(), &modules, @sizeOf(@TypeOf(modules)), &needed) == 0) {
        return pp_format.panicf("ffi: %s", .{@as([*]const u8, @ptrCast(errorClib()))});
    }

    const count = needed / @sizeOf(?*anyopaque);
    var i: u32 = 0;
    while (i < count and i < modules.len) : (i += 1) {
        if (c.GetProcAddress(modules[i], sym)) |address| return address;
    }
    return null;
}
