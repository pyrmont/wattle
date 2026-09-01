//! Loading a native module: a library handle and the four operations over it,
//! for POSIX, for Windows, and for a build with dynamic modules turned off.
//!
//! Two things happen in this file, and they are separable.
//!
//! **The Win32 loader.** On POSIX `load_clib`, `symbol_clib`, `free_clib` and
//! `error_clib` are macros onto `dlopen`, `dlsym`, `dlclose` and `dlerror`, so
//! there is nothing to write. On Windows all four are real functions.
//!
//! **One copy rather than two.** The FFI and the core environment each carried
//! this block while they were separate objects, and the duplication had
//! drifted -- one copy's `Handle` carried a redundant branch, and only one had
//! `free`.
//!
//! ## Why `symbol` raises and the others do not
//!
//! Exactly one path here can fail in a way a Janet program should see:
//! `symbol_clib`, asked for a symbol in the *process* rather than in a loaded
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
//! checking and no more, so the code below is written to be read against
//! Janet's line by line, and the one place it deliberately differs says so.

const std = @import("std");
const builtin = @import("builtin");
const raise = @import("raise.zig");
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
/// head of this file has the reason.
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
/// `dlerror` answers null when nothing has failed, and the C original hands
/// that straight on -- to `janet_panic` in `ffi.c` and to `janet_cstring` in
/// `corelib.c`, both of which would walk from address zero. It is unreachable
/// through either caller, each of which reaches this only on the branch a
/// failed `dlopen` took, and the null arm is written out rather than left
/// implicit because Zig's type says it can happen.
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

/// The abi under Janet's name for it. Nothing in this tree calls it; it is
/// published because Janet published it.
/// `c.FormatMessageA`'s buffer. Static in the C original and static here, so the
/// answer is valid until the next failure on any thread -- which is a race the
/// C original also has and which nothing in the tree can reach twice.
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

    // Janet's own line is `error_clib_buf[strlen(error_clib_buf) - 1] = '\0'`,
    // which strips the newline `c.FormatMessageA` appends. **When the call
    // writes nothing it indexes [-1]**, which is a write outside the array;
    // `FOUND.md` has it. That is undefined rather than merely wrong, so this
    // records it instead of reproducing it and the strip is guarded. Every
    // other input behaves identically.
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
/// The second case is what `(ffi/native)` with no path asks for. The C
/// original's fixed array of 1024 module handles is kept: `c.EnumProcessModules`
/// reports how much it *wanted* in `needed`, and neither implementation grows
/// the array or notices the truncation, so a process with more than 1024
/// modules silently searches the first 1024. Reproduced -- it is defined
/// behaviour, just a limit nobody documented.
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
