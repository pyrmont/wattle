//! The filesystem half of `os.c`'s cfunction surface: the six operations
//! `-Dos-fs` already had kernels for, the six `-Dos-fs-paths` had, `os/stat`
//! and its three relatives over `-Dos-stat`, the two permission conversions
//! over `-Dos-permissions`, and `os/open`. This is Phase 10 Part 12.
//!
//! ## Where the permission helpers live, and why here
//!
//! `os_get_unix_mode` is `os.c`'s, and five cfunctions in three different
//! `-Dos-*` subjects call it: `os/perm-string`, `os/perm-int`, `os/chmod`,
//! `os/umask` and `os/open`. It raises, so under Part 4's seam rule it could
//! not have crossed a *selector* boundary as an error union. It does not have
//! to: the whole surface is one selector and one object, so these are ordinary
//! Zig calls and the fault propagates as a `raise.Error` rather than being
//! delivered as a jump. That is the concrete thing folding the four files into
//! one object buys, and it is the same argument `makePpObject` records.
//!
//! ## `struct stat` cannot be named from Zig, and that is measured
//!
//! Decision 4 unparks the host structures and says they stay libc's, reached
//! with `@cImport`. `struct stat` is the one place in this increment where
//! that does not work, and the reason is Part 11's `FILE` lesson repeating one
//! layer down. musl declares `struct timespec` with a bitfield -- padding
//! written as `int :8*(sizeof(time_t)-sizeof(long))*(__BYTE_ORDER==4321)` --
//! and translate-c demotes any structure with a bitfield to `opaque {}`.
//! `struct stat` embeds three of them, so it is demoted in turn, and Zig can
//! neither size it nor place one on the stack. Verified on all three musl
//! targets; macOS and mingw both translate it completely, which is exactly
//! what makes it easy to miss.
//!
//! So `os.c` keeps one function, `janet_zig_os_stat_read`. It is the *only*
//! thing left in that file besides its licence header: it stats a path and
//! copies out the mode word and one double per numeric field. Every Janet
//! value `os/stat` produces is built here, and the fifteen getters are gone.
//! The array it fills is zeroed first, because Part 5's lesson applies to it
//! exactly -- "a descriptor's unwritten fields are part of its contract and
//! nothing about the type says so" -- and two of the fifteen slots are never
//! written on Windows.
//!
//! ## Windows directory enumeration moved after all
//!
//! `src/zig/README.md` records under `-Dos-fs-paths` that `_findfirst` fills a
//! `struct _finddata_t` "whose layout depends on the CRT's `time_t`
//! configuration, so it falls under the same rule as `jstat_t`". That was
//! right about the rule and wrong about this structure: mingw resolves
//! `_finddata_t` to `_finddata64i32_t` in the header, translate-c renders it
//! completely, and the three `_find*` aliases come through with it. The
//! enumeration is written here and compiled on every target the same way the
//! Windows command-line escaping is.
//!
//! ## The marker
//!
//! Every raise in this file is an error return. It carries the marker anyway,
//! for the reason `io_core.zig` does: `janet_arity`, `janet_getcstring`,
//! `janet_sandbox_assert` and their relatives are `-Dargs-core`'s and
//! `-Dvm-lifecycle`'s C faces, and each raises by jumping. `os/realpath` is
//! where that is visible -- the host allocates the path and C frees it, and a
//! jump out of `janet_cstringv` would strand the allocation exactly as it does
//! in the C original.

const std = @import("std");
const builtin = @import("builtin");
const abi = @import("abi");
const oa = @import("os_abi");
const corefn = @import("corefn");
const raise = @import("raise");
const pp_format = @import("pp_format.zig");
const c = abi.c;
const host_stat = @import("host_stat.zig");
const evloop = @import("evloop.zig");
const lifecycle = @import("lifecycle.zig");
const containers = @import("containers.zig");
const arglayer = @import("arglayer.zig");
const h = oa.h;

const windows = builtin.os.tag == .windows;

// Janet's platform macros are *not* read through the translation, and this
// increment found out why. `janet.h` derives `JANET_WINDOWS` from the
// compiler's own predefined macros, and Aro -- translate-c's front end --
// predefines `__unix__`, `unix` and `__unix` for `x86_64-windows-gnu` on top
// of `_WIN32`. `janet.h` tests its Unix chain first, so the *translation* of
// that header defines `JANET_POSIX` where the *compilation* of the same
// header for the same target defines `JANET_WINDOWS`. `@hasDecl` is therefore
// reserved for macros the build writes into `janetconf.h`, and every platform
// test in this object goes through `builtin.os.tag`.
comptime {
    if (@hasDecl(c, "JANET_WINDOWS") and !windows)
        @compileError("platform tests must not read janet.h's derived macros");
}

pub const no_symlinks = @hasDecl(c, "JANET_NO_SYMLINKS");
pub const no_realpath = @hasDecl(c, "JANET_NO_REALPATH");
pub const no_umask = @hasDecl(c, "JANET_NO_UMASK");
pub const has_ev = @hasDecl(c, "JANET_EV");

comptime {
    if (has_ev != (c.JANET_VM_HAS_EV != 0))
        @compileError("JANET_EV disagrees with state_abi.h's restatement");
}

// ==========================================================================
// The kernels this surface sits on, reached across the C ABI
//
// Each is `-Dos-*`'s export and may be either implementation, which is what
// keeps those eight selectors meaningful now that the surface above them is
// Zig. They are declared here rather than translated because they are
// declared inside `os.c` rather than in any header.
// ==========================================================================

extern fn janet_os_getcwd(buffer: [*]u8, size: i32) callconv(.c) i32;
extern fn janet_os_mkdir(path: [*:0]const u8) callconv(.c) i32;
extern fn janet_os_rmdir(path: [*:0]const u8) callconv(.c) i32;
extern fn janet_os_chdir(path: [*:0]const u8) callconv(.c) i32;
extern fn janet_os_remove(path: [*:0]const u8) callconv(.c) i32;
extern fn janet_os_rename(old: [*:0]const u8, new: [*:0]const u8) callconv(.c) i32;

extern fn janet_os_dir_open(path: [*:0]const u8) callconv(.c) ?*anyopaque;
extern fn janet_os_dir_next(handle: *anyopaque, name: *[*:0]const u8) callconv(.c) i32;
extern fn janet_os_dir_close(handle: *anyopaque) callconv(.c) void;
extern fn janet_os_link(old: [*:0]const u8, new: [*:0]const u8) callconv(.c) i32;
extern fn janet_os_symlink(old: [*:0]const u8, new: [*:0]const u8) callconv(.c) i32;
extern fn janet_os_readlink(path: [*:0]const u8, buffer: [*]u8, size: usize) callconv(.c) i64;
extern fn janet_os_touch(path: [*:0]const u8, has_times: i32, actime: f64, modtime: f64) callconv(.c) i32;
extern fn janet_os_realpath(path: [*:0]const u8) callconv(.c) ?[*:0]u8;

extern fn janet_os_mode_name(mode: u32) callconv(.c) [*:0]const u8;
extern fn janet_os_decode_permissions(mode: u32) callconv(.c) i32;
extern fn janet_os_perm_to_unix(mode: u32) callconv(.c) i32;
extern fn janet_os_perm_from_unix(permissions: i32) callconv(.c) u32;
/// `-Dos-stat`'s field registry, by import. These were `export fn`s reached
/// back through the linker, which is the shape `os.c` needed; Phase 11 Part 20
/// spent the three symbols along with `test/os_surface.c`, their last reader
/// outside this file.
const os_stat = @import("os_stat.zig");

extern fn janet_os_parse_permissions(perm: [*]const u8) callconv(.c) i32;
extern fn janet_os_format_permissions(permissions: i32, out: [*]u8) callconv(.c) void;

/// `host_stat.zig` since Phase 10 Part 18. The measurement at the head of this
/// file still holds -- musl's `struct stat` is `opaque {}` after translation --
/// and what changed is the answer: `statx` on Linux, whose structure Zig
/// defines itself, and `@cImport` on macOS and mingw, which translate `struct
/// stat` completely.
const janet_zig_os_stat_read = host_stat.statReadFaceCompat;

/// `src/core/util.h`, which `abi.zig` deliberately does not translate.
extern fn janet_strerror(e: c_int) callconv(.c) [*c]const u8;

/// `janet_wrap_integer`, written out rather than called. `janet.h` declares the
/// function beside its macro and `wrap.c` defines it only for the two nanbox
/// layouts, so a tagged build has no such symbol and a Zig caller -- which
/// cannot use the macro -- does not link. `marsh.zig`, `pp_pretty.zig` and
/// `value_access.zig` write it out for the same reason, and `FOUND.md` has the
/// defect. This is the fourth subsystem to meet it.
inline fn wrapInteger(x: i32) c.Janet {
    return c.janet_wrap_number(@floatFromInt(x));
}

inline fn errno() c_int {
    return std.c._errno().*;
}

// ==========================================================================
// Permissions
// ==========================================================================

/// The field identifiers `-Dos-stat`'s registry fixes, by position. The
/// registry itself is that subsystem's and is reached by name; these are the
/// indices into it, and `test/os_stat.c` already pins the order both sides
/// agree on.
const Field = enum(i32) {
    dev,
    inode,
    mode,
    int_permissions,
    permissions,
    uid,
    gid,
    nlink,
    rdev,
    size,
    blocks,
    blocksize,
    accessed,
    modified,
    changed,
};

const field_count = @typeInfo(Field).@"enum".fields.len;

/// `os_make_permstring`.
fn makePermstring(permissions: i32) c.Janet {
    var bytes: [9]u8 = undefined;
    janet_os_format_permissions(permissions, &bytes);
    return c.janet_stringv(&bytes, bytes.len);
}

/// `os_get_unix_mode`: an integer in `[0, 8r777]` or a nine-byte `rwx` string.
///
/// Shared by five cfunctions across three `-Dos-*` subjects. See the head of
/// this file for why that is an ordinary Zig call rather than a seam.
pub fn getUnixMode(argv: [*c]const c.Janet, n: i32) raise.Raising(i32) {
    if (c.janet_checkint(argv[@intCast(n)]) != 0) {
        const x = c.janet_unwrap_integer(argv[@intCast(n)]);
        if (x < 0 or x > 0o777) {
            return pp_format.panicf(
                "bad slot #%d, expected integer in range [0, 8r777], got %v",
                .{ n, argv[@intCast(n)] },
            );
        }
        return x;
    }
    const bytes = try arglayer.getBytes(argv, n);
    if (bytes.len != 9) {
        return pp_format.panicf(
            "bad slot #%d: expected byte sequence of length 9, got %v",
            .{ n, argv[@intCast(n)] },
        );
    }
    return janet_os_parse_permissions(bytes.bytes);
}

/// `os_getmode`: the same value, converted to what the host's `chmod` takes.
///
/// `jmode_t` is `mode_t` on POSIX and `unsigned short` on Windows; both are
/// scalars, so nothing here depends on a host layout.
const jmode_t = if (windows) c_ushort else h.mode_t;

pub fn getMode(argv: [*c]const c.Janet, n: i32) raise.Raising(jmode_t) {
    return @intCast(janet_os_perm_from_unix(try getUnixMode(argv, n)));
}

/// `os_optmode`.
fn optMode(argc: i32, argv: [*c]const c.Janet, n: i32, dflt: i32) raise.Raising(jmode_t) {
    if (argc > n) return getMode(argv, n);
    return @intCast(janet_os_perm_from_unix(dflt));
}

pub fn cfunPermissionString(argc: i32, argv: [*c]c.Janet) align(corefn.alignment) raise.Raising(c.Janet) {
    try arglayer.fixarity(argc, 1);
    return makePermstring(try getUnixMode(argv, 0));
}

pub fn cfunPermissionInt(argc: i32, argv: [*c]c.Janet) align(corefn.alignment) raise.Raising(c.Janet) {
    try arglayer.fixarity(argc, 1);
    return wrapInteger(try getUnixMode(argv, 0));
}

// ==========================================================================
// Basic filesystem operations
// ==========================================================================

fn cwdImpl(argc: i32, argv: [*c]c.Janet) raise.Raising(c.Janet) {
    _ = argv;
    try arglayer.fixarity(argc, 0);
    var buf: [h.FILENAME_MAX]u8 = undefined;
    if (janet_os_getcwd(&buf, h.FILENAME_MAX) != 0) {
        return raise.panic("could not get current directory");
    }
    return c.janet_cstringv(&buf);
}

fn mkdirImpl(argc: i32, argv: [*c]c.Janet) raise.Raising(c.Janet) {
    try lifecycle.sandboxAssert(c.JANET_SANDBOX_FS_WRITE);
    try arglayer.fixarity(argc, 1);
    const path = try arglayer.getCString(argv, 0);
    const res = janet_os_mkdir(@ptrCast(path));
    if (res == 0) return c.janet_wrap_true();
    if (errno() == h.EEXIST) return c.janet_wrap_false();
    return pp_format.panicf("%s: %s", .{ janet_strerror(errno()), path });
}

fn rmdirImpl(argc: i32, argv: [*c]c.Janet) raise.Raising(c.Janet) {
    try lifecycle.sandboxAssert(c.JANET_SANDBOX_FS_WRITE);
    try arglayer.fixarity(argc, 1);
    const path = try arglayer.getCString(argv, 0);
    if (janet_os_rmdir(@ptrCast(path)) == -1) {
        return pp_format.panicf("%s: %s", .{ janet_strerror(errno()), path });
    }
    return c.janet_wrap_nil();
}

fn cdImpl(argc: i32, argv: [*c]c.Janet) raise.Raising(c.Janet) {
    try lifecycle.sandboxAssert(c.JANET_SANDBOX_FS_READ);
    try arglayer.fixarity(argc, 1);
    const path = try arglayer.getCString(argv, 0);
    if (janet_os_chdir(@ptrCast(path)) == -1) {
        return pp_format.panicf("%s: %s", .{ janet_strerror(errno()), path });
    }
    return c.janet_wrap_nil();
}

/// The sandbox assertion here is a *fix*, not a reproduction, and it is the
/// one place this increment deliberately departs from the C original's
/// behaviour by agreement rather than by rule.
///
/// `os.c` asserted nothing in `os/rm`, while `os/mkdir`, `os/rmdir`, `os/cd`,
/// `os/rename`, `os/touch`, `os/chmod`, `os/umask`, `os/link` and `os/symlink`
/// all assert `JANET_SANDBOX_FS_WRITE` -- so a program under a full filesystem
/// sandbox could still delete any file the process could reach. `FOUND.md`
/// keeps the entry for reporting upstream; `src/core/os.c` carries the same
/// fix, because the two implementations have to stay observationally
/// identical or the differential testing this project rests on means nothing.
fn removeImpl(argc: i32, argv: [*c]c.Janet) raise.Raising(c.Janet) {
    try lifecycle.sandboxAssert(c.JANET_SANDBOX_FS_WRITE);
    try arglayer.fixarity(argc, 1);
    const path = try arglayer.getCString(argv, 0);
    if (janet_os_remove(@ptrCast(path)) == -1) {
        return pp_format.panicf("%s: %s", .{ janet_strerror(errno()), path });
    }
    return c.janet_wrap_nil();
}

/// The one failure message in this family that is a bare `janet_panic` over
/// `janet_strerror` rather than a `%s: %s` naming the path. Reproduced.
fn renameImpl(argc: i32, argv: [*c]c.Janet) raise.Raising(c.Janet) {
    try lifecycle.sandboxAssert(c.JANET_SANDBOX_FS_WRITE);
    try arglayer.fixarity(argc, 2);
    const src = try arglayer.getCString(argv, 0);
    const dest = try arglayer.getCString(argv, 1);
    if (janet_os_rename(@ptrCast(src), @ptrCast(dest)) != 0) {
        return raise.panic(@ptrCast(janet_strerror(errno())));
    }
    return c.janet_wrap_nil();
}

fn touchImpl(argc: i32, argv: [*c]c.Janet) raise.Raising(c.Janet) {
    try lifecycle.sandboxAssert(c.JANET_SANDBOX_FS_WRITE);
    try arglayer.arity(argc, 1, 3);
    const path = try arglayer.getCString(argv, 0);
    var actime: f64 = 0;
    var modtime: f64 = 0;
    if (argc >= 2) {
        actime = try arglayer.getNumber(argv, 1);
        modtime = if (argc >= 3) try arglayer.getNumber(argv, 2) else actime;
    }
    if (janet_os_touch(@ptrCast(path), @intFromBool(argc >= 2), actime, modtime) == -1) {
        return raise.panic(@ptrCast(janet_strerror(errno())));
    }
    return c.janet_wrap_nil();
}

// ==========================================================================
// Links
// ==========================================================================

/// `j_symlink`: with `JANET_NO_SYMLINKS` the symbolic-link entry points do not
/// exist and `os/link`'s `symlink` argument silently makes a hard link
/// instead. `src/zig/README.md` records that such a build must select
/// `-Dos-fs-paths=c`, because that object always references `symlink` and
/// `readlink`; the same now goes for this one, and the `#define` is
/// reproduced here so the two agree about which function is called.
inline fn symlinkOrLink(old: [*:0]const u8, new: [*:0]const u8) i32 {
    return if (no_symlinks) janet_os_link(old, new) else janet_os_symlink(old, new);
}

fn linkImpl(argc: i32, argv: [*c]c.Janet) raise.Raising(c.Janet) {
    try lifecycle.sandboxAssert(c.JANET_SANDBOX_FS_WRITE);
    try arglayer.arity(argc, 2, 3);
    if (windows) return raise.panic("not supported on Windows or Plan 9");
    const oldpath = try arglayer.getCString(argv, 0);
    const newpath = try arglayer.getCString(argv, 1);
    const symbolic = argc == 3 and c.janet_truthy(argv[2]) != 0;
    const res = if (symbolic)
        symlinkOrLink(@ptrCast(oldpath), @ptrCast(newpath))
    else
        janet_os_link(@ptrCast(oldpath), @ptrCast(newpath));
    if (res == -1) {
        return pp_format.panicf("%s: %s -> %s", .{ janet_strerror(errno()), oldpath, newpath });
    }
    return c.janet_wrap_nil();
}

fn symlinkImpl(argc: i32, argv: [*c]c.Janet) raise.Raising(c.Janet) {
    try lifecycle.sandboxAssert(c.JANET_SANDBOX_FS_WRITE);
    try arglayer.fixarity(argc, 2);
    if (windows) return raise.panic("not supported on Windows or Plan 9");
    const oldpath = try arglayer.getCString(argv, 0);
    const newpath = try arglayer.getCString(argv, 1);
    if (symlinkOrLink(@ptrCast(oldpath), @ptrCast(newpath)) == -1) {
        return pp_format.panicf("%s: %s -> %s", .{ janet_strerror(errno()), oldpath, newpath });
    }
    return c.janet_wrap_nil();
}

/// Like `os/rm`, this one asserts no sandbox permission.
fn readlinkImpl(argc: i32, argv: [*c]c.Janet) raise.Raising(c.Janet) {
    try arglayer.fixarity(argc, 1);
    if (windows) return raise.panic("not supported on Windows");
    var buffer: [oa.path_max]u8 = undefined;
    const path = try arglayer.getCString(argv, 0);
    const len = janet_os_readlink(@ptrCast(path), &buffer, buffer.len);
    if (len < 0 or @as(usize, @intCast(len)) >= buffer.len) {
        return pp_format.panicf("%s: %s", .{ janet_strerror(errno()), path });
    }
    return c.janet_stringv(&buffer, @as(i32, @intCast(len)));
}

/// The host allocates the path and this frees it, on the POSIX/Windows split
/// `FOUND.md` records: `janet_os_realpath` is `realpath` on POSIX and
/// `_fullpath` on Windows, and the Windows result is released with the plain
/// `free` rather than Janet's, because `_fullpath` used the plain `malloc`.
///
/// The `janet_cstringv` between the allocation and the release can raise, and
/// a raise here strands the allocation. That is the C original's behaviour and
/// the reason this file carries the jump-transparent marker rather than a
/// `defer`.
extern fn free(ptr: ?*anyopaque) callconv(.c) void;
extern fn janet_free(ptr: ?*anyopaque) callconv(.c) void;
extern fn GetFileAttributesA(name: [*:0]const u8) callconv(.c) u32;

fn realpathImpl(argc: i32, argv: [*c]c.Janet) raise.Raising(c.Janet) {
    try lifecycle.sandboxAssert(c.JANET_SANDBOX_FS_READ);
    try arglayer.fixarity(argc, 1);
    const src = try arglayer.getCString(argv, 0);
    if (no_realpath) return raise.panic("os/realpath not enabled for this platform");
    const dest = janet_os_realpath(@ptrCast(src)) orelse {
        return pp_format.panicf("%s: %s", .{ janet_strerror(errno()), src });
    };
    const ret = c.janet_cstringv(dest);
    if (windows) {
        const attrib = GetFileAttributesA(dest);
        free(dest);
        if (attrib == 0xFFFF_FFFF) return pp_format.panicf("path does not exist: %v", .{ret});
    } else {
        janet_free(dest);
    }
    return ret;
}

// ==========================================================================
// Directory enumeration
// ==========================================================================

/// The Windows enumeration, written here rather than left in C. See the head
/// of this file: `_finddata_t` translates completely on mingw, which the
/// `-Dos-fs-paths` note assumed it would not.
fn dirWindows(dir: [*c]const u8, paths: *c.JanetArray) raise.Raising(void) {
    var afile: h._finddata_t = undefined;
    var pattern: [h.MAX_PATH + 1]u8 = undefined;
    const dirlen = std.mem.len(@as([*:0]const u8, @ptrCast(dir)));
    if (dirlen > pattern.len - 3) return pp_format.panicf("path too long: %s", .{dir});
    _ = std.fmt.bufPrintZ(&pattern, "{s}/*", .{@as([*:0]const u8, @ptrCast(dir))}) catch unreachable;
    const res = h._findfirst(&pattern, &afile);
    if (res == -1) return raise.panicv(c.janet_cstringv(janet_strerror(errno())));
    while (true) {
        const name: [*:0]const u8 = @ptrCast(&afile.name);
        if (!std.mem.eql(u8, std.mem.span(name), ".") and
            !std.mem.eql(u8, std.mem.span(name), ".."))
        {
            try containers.arrayPush(paths, c.janet_cstringv(name));
        }
        if (h._findnext(res, &afile) == -1) break;
    }
    _ = h._findclose(res);
}

/// The POSIX enumeration, through `-Dos-fs-paths`'s explicit iterator. The
/// close-then-panic on a failed read is the C original's, and the errno is
/// saved across the close because closing can overwrite it.
fn dirPosix(dir: [*c]const u8, paths: *c.JanetArray) raise.Raising(void) {
    const dfd = janet_os_dir_open(@ptrCast(dir)) orelse {
        return pp_format.panicf("cannot open directory %s: %s", .{ dir, janet_strerror(errno()) });
    };
    while (true) {
        var name: [*:0]const u8 = undefined;
        const status = janet_os_dir_next(dfd, &name);
        if (status < 0) {
            const olderr = errno();
            janet_os_dir_close(dfd);
            return pp_format.panicf("failed to read directory %s: %s", .{ dir, janet_strerror(olderr) });
        }
        if (status == 0) break;
        try containers.arrayPush(paths, c.janet_cstringv(name));
    }
    janet_os_dir_close(dfd);
}

fn dirImpl(argc: i32, argv: [*c]c.Janet) raise.Raising(c.Janet) {
    try lifecycle.sandboxAssert(c.JANET_SANDBOX_FS_READ);
    try arglayer.arity(argc, 1, 2);
    const dir = try arglayer.getCString(argv, 0);
    const paths = if (argc == 2) try arglayer.getArray(argv, 1) else c.janet_array(0);
    if (windows) try dirWindows(dir, paths) else try dirPosix(dir, paths);
    return c.janet_wrap_array(paths);
}

// ==========================================================================
// Metadata
// ==========================================================================

/// Build the Janet value for one field out of what `janet_zig_os_stat_read`
/// copied out. Every one of the fifteen is constructed here; C keeps only the
/// read.
fn statField(field: Field, mode: u32, numbers: *const [field_count]f64) c.Janet {
    return switch (field) {
        .mode => c.janet_wrap_keyword(c.janet_ckeyword(janet_os_mode_name(mode))),
        .int_permissions => wrapInteger(
            janet_os_perm_to_unix(@bitCast(janet_os_decode_permissions(mode))),
        ),
        .permissions => makePermstring(
            janet_os_perm_to_unix(@bitCast(janet_os_decode_permissions(mode))),
        ),
        else => c.janet_wrap_number(numbers[@intCast(@intFromEnum(field))]),
    };
}

fn statOrLstat(do_lstat: bool, argc: i32, argv: [*c]c.Janet) raise.Raising(c.Janet) {
    try lifecycle.sandboxAssert(c.JANET_SANDBOX_FS_READ);
    try arglayer.arity(argc, 1, 2);
    const path = try arglayer.getCString(argv, 0);
    var tab: ?*c.JanetTable = null;
    var key: ?c.JanetKeyword = null;
    if (argc == 2) {
        if (c.janet_checktype(argv[1], c.JANET_KEYWORD) != 0) {
            key = try arglayer.getKeyword(argv, 1);
        } else {
            tab = try arglayer.getTable(argv, 1);
        }
    } else {
        tab = c.janet_table(0);
    }

    var mode: u32 = 0;
    var numbers: [field_count]f64 = @splat(0);
    if (janet_zig_os_stat_read(@ptrCast(path), @intFromBool(do_lstat), &mode, &numbers) == -1) {
        return c.janet_wrap_nil();
    }

    if (key) |k| {
        const field = os_stat.fieldLookup(k, c.janet_string_length(k));
        if (field < 0) return pp_format.panicf("unexpected keyword %v", .{c.janet_wrap_keyword(k)});
        return statField(@enumFromInt(field), mode, &numbers);
    }
    // The registry's count is `-Dos-stat`'s, and this walks it rather than
    // `field_count` so that the two cannot silently disagree.
    const count = os_stat.fieldCount();
    var field: i32 = 0;
    while (field < count) : (field += 1) {
        c.janet_table_put(
            tab.?,
            c.janet_ckeywordv(os_stat.fieldName(field).?),
            statField(@enumFromInt(field), mode, &numbers),
        );
    }
    return c.janet_wrap_table(tab.?);
}

extern fn chmod(path: [*:0]const u8, mode: jmode_t) callconv(.c) c_int;
extern fn _chmod(path: [*:0]const u8, mode: c_int) callconv(.c) c_int;
extern fn umask(mask: jmode_t) callconv(.c) jmode_t;
extern fn _umask(mask: c_int) callconv(.c) c_int;

fn chmodImpl(argc: i32, argv: [*c]c.Janet) raise.Raising(c.Janet) {
    try lifecycle.sandboxAssert(c.JANET_SANDBOX_FS_WRITE);
    try arglayer.fixarity(argc, 2);
    const path = try arglayer.getCString(argv, 0);
    const mode = try getMode(argv, 1);
    const res = if (windows) _chmod(@ptrCast(path), mode) else chmod(@ptrCast(path), mode);
    if (res == -1) return pp_format.panicf("%s: %s", .{ janet_strerror(errno()), path });
    return c.janet_wrap_nil();
}

fn umaskImpl(argc: i32, argv: [*c]c.Janet) raise.Raising(c.Janet) {
    try lifecycle.sandboxAssert(c.JANET_SANDBOX_FS_WRITE);
    try arglayer.fixarity(argc, 1);
    const mask = try getMode(argv, 0);
    const res = if (windows) _umask(mask) else umask(mask);
    return wrapInteger(janet_os_perm_to_unix(@intCast(res)));
}

// ==========================================================================
// `os/open`
// ==========================================================================
//
// Compiled only under the event loop, because it produces a `JanetStream`.
// Zig does not analyse a function nothing references, so the registration
// table's comptime `if` is what keeps this out of a `-Dev=false` build --
// `janet_stream` is not declared there at all.

const stream_readable: u32 = 0x200;
const stream_writable: u32 = 0x400;

/// The flag letters `os/open` accepts. Both vocabularies are compiled on every
/// target, and only one is reachable; the rule they implement belongs to the
/// host's `open` interface rather than to the machine running the build, which
/// is the same reason `-Dos-process` compiles the Windows command-line
/// escaping everywhere.
const OpenScan = struct {
    stream_flags: u32 = 0,
    disable_stream_mode: bool = false,
};

fn openPosix(opt_flags: [*:0]const u8, scan: *OpenScan) raise.Raising(c_int) {
    var open_flags: c_int = h.O_NONBLOCK;
    if (builtin.os.tag == .linux) open_flags |= h.O_CLOEXEC;
    var read_flag = false;
    var write_flag = false;
    var i: usize = 0;
    while (opt_flags[i] != 0) : (i += 1) {
        switch (opt_flags[i]) {
            'r' => {
                read_flag = true;
                scan.stream_flags |= stream_readable;
                try lifecycle.sandboxAssert(c.JANET_SANDBOX_FS_READ);
            },
            'w' => {
                write_flag = true;
                scan.stream_flags |= stream_writable;
                try lifecycle.sandboxAssert(c.JANET_SANDBOX_FS_WRITE);
            },
            'c' => {
                open_flags |= h.O_CREAT;
                try lifecycle.sandboxAssert(c.JANET_SANDBOX_FS_WRITE);
            },
            'e' => open_flags |= h.O_EXCL,
            't' => {
                open_flags |= h.O_TRUNC;
                try lifecycle.sandboxAssert(c.JANET_SANDBOX_FS_WRITE);
            },
            'x' => open_flags |= h.O_SYNC,
            'C' => open_flags |= h.O_NOCTTY,
            'a' => open_flags |= h.O_APPEND,
            'N' => {
                open_flags &= ~@as(c_int, h.O_NONBLOCK);
                scan.disable_stream_mode = true;
            },
            else => {},
        }
    }
    // The C original's three-way fixup, including its last arm: neither flag
    // and both flags alike give O_RDWR.
    if (read_flag and !write_flag) {
        open_flags |= h.O_RDONLY;
    } else if (write_flag and !read_flag) {
        open_flags |= h.O_WRONLY;
    } else {
        open_flags |= h.O_RDWR;
    }
    return open_flags;
}

const WindowsOpen = struct {
    desired_access: u32 = 0,
    share_mode: u32 = 0,
    creation_disp: u32 = 0,
    file_flags: u32 = 0,
    file_attributes: u32 = 0,
    inherited_handle: bool = false,
};

fn openWindows(opt_flags: [*:0]const u8, scan: *OpenScan) raise.Raising(WindowsOpen) {
    const o_creat: u32 = 1;
    const o_excl: u32 = 2;
    const o_trunc: u32 = 4;
    var w: WindowsOpen = .{ .file_flags = h.FILE_FLAG_OVERLAPPED };
    var creat_unix: u32 = 0;
    var i: usize = 0;
    while (opt_flags[i] != 0) : (i += 1) {
        switch (opt_flags[i]) {
            'r' => {
                w.desired_access |= h.GENERIC_READ;
                scan.stream_flags |= stream_readable;
                try lifecycle.sandboxAssert(c.JANET_SANDBOX_FS_READ);
            },
            'w' => {
                w.desired_access |= h.GENERIC_WRITE;
                scan.stream_flags |= stream_writable;
                try lifecycle.sandboxAssert(c.JANET_SANDBOX_FS_WRITE);
            },
            'a' => {
                w.desired_access |= h.FILE_APPEND_DATA;
                scan.stream_flags |= stream_writable;
                try lifecycle.sandboxAssert(c.JANET_SANDBOX_FS_WRITE);
            },
            'c' => {
                creat_unix |= o_creat;
                try lifecycle.sandboxAssert(c.JANET_SANDBOX_FS_WRITE);
            },
            'e' => creat_unix |= o_excl,
            't' => {
                creat_unix |= o_trunc;
                try lifecycle.sandboxAssert(c.JANET_SANDBOX_FS_WRITE);
            },
            'D' => w.share_mode |= h.FILE_SHARE_DELETE,
            'R' => w.share_mode |= h.FILE_SHARE_READ,
            'W' => w.share_mode |= h.FILE_SHARE_WRITE,
            'H' => w.file_attributes |= h.FILE_ATTRIBUTE_HIDDEN,
            'O' => w.file_attributes |= h.FILE_ATTRIBUTE_READONLY,
            'F' => w.file_attributes |= h.FILE_ATTRIBUTE_OFFLINE,
            'T' => w.file_attributes |= h.FILE_ATTRIBUTE_TEMPORARY,
            'd' => w.file_flags |= h.FILE_FLAG_DELETE_ON_CLOSE,
            'b' => w.file_flags |= h.FILE_FLAG_NO_BUFFERING,
            'I' => w.inherited_handle = true,
            'V' => {
                w.file_flags &= ~@as(u32, h.FILE_FLAG_OVERLAPPED);
                scan.disable_stream_mode = true;
            },
            else => {},
        }
    }
    w.creation_disp = switch (creat_unix) {
        0 => h.OPEN_EXISTING,
        o_creat => h.OPEN_ALWAYS,
        o_creat + o_excl => h.CREATE_NEW,
        o_creat + o_trunc => h.CREATE_ALWAYS,
        o_trunc => h.TRUNCATE_EXISTING,
        else => return raise.panic("invalid creation flags"),
    };
    if (w.file_attributes == 0) w.file_attributes = h.FILE_ATTRIBUTE_NORMAL;
    return w;
}

extern fn open(path: [*:0]const u8, flags: c_int, ...) callconv(.c) c_int;

fn openImpl(argc: i32, argv: [*c]c.Janet) raise.Raising(c.Janet) {
    try arglayer.arity(argc, 1, 3);
    const path = try arglayer.getCString(argv, 0);
    const opt_flags: [*:0]const u8 = @ptrCast(try arglayer.optKeyword(argv, argc, 1, "r"));
    const mode = try optMode(argc, argv, 2, 0o666);
    var scan: OpenScan = .{};
    var fd: c.JanetHandle = undefined;
    if (windows) {
        const w = try openWindows(opt_flags, &scan);
        var sa_attr: h.SECURITY_ATTRIBUTES = std.mem.zeroes(h.SECURITY_ATTRIBUTES);
        sa_attr.nLength = @sizeOf(h.SECURITY_ATTRIBUTES);
        if (w.inherited_handle) sa_attr.bInheritHandle = 1;
        fd = h.CreateFileA(
            path,
            w.desired_access,
            w.share_mode,
            &sa_attr,
            w.creation_disp,
            w.file_flags | w.file_attributes,
            null,
        );
        if (fd == h.INVALID_HANDLE_VALUE) return raise.panicv(c.janet_ev_lasterr());
    } else {
        const open_flags = try openPosix(opt_flags, &scan);
        while (true) {
            fd = open(@ptrCast(path), open_flags, mode);
            if (!(fd == -1 and errno() == h.EINTR)) break;
        }
        if (fd == -1) return raise.panicv(c.janet_ev_lasterr());
    }
    const flags = if (scan.disable_stream_mode) 0 else scan.stream_flags;
    return c.janet_wrap_abstract(try evloop.makeStream(fd, flags, null));
}

// ==========================================================================
// The C faces
//
// Part 10's finding applied rather than restated: a cfunction that decides to
// raise is an `Impl` behind a two-line face, and one that makes no such
// decision stays a plain `JanetCFunction`. Every cfunction in this file
// decides, because every one of them reports a host failure.
// ==========================================================================

fn statImpl(argc: i32, argv: [*c]c.Janet) raise.Raising(c.Janet) {
    return statOrLstat(false, argc, argv);
}

fn lstatImpl(argc: i32, argv: [*c]c.Janet) raise.Raising(c.Janet) {
    return statOrLstat(true, argc, argv);
}

// ==========================================================================
// Registration
//
// The rows this file contributes to `janet_lib_os`. The root assembles them;
// see `os_surface.zig` for why the table cannot be split across selectors.
// ==========================================================================

/// `@src()` is only valid inside a function, so a table that wants to record
/// its own rows has to be built in one. `comptime` makes the result a
/// compile-time constant all the same, and taking its address promotes it to
/// static storage, so nothing is assembled at run time.
pub fn entries() []const corefn.Entry {
    const list = comptime blk: {
        var acc: []const corefn.Entry = &.{};
        acc = acc ++ [_]corefn.Entry{
            corefn.reg("os/cwd", &cwdImpl, @src(), "(os/cwd)", "Returns the current working directory."),
            corefn.reg("os/perm-string", &cfunPermissionString, @src(), "(os/perm-string int)", "Convert a Unix octal permission value from a permission integer as returned by `os/stat` " ++
                "to a human readable string, that follows the formatting " ++
                "of Unix tools like `ls`. Returns the string as a 9-character string of r, w, x and - characters. Does not " ++
                "include the file/directory/symlink character as rendered by `ls`."),
            corefn.reg("os/perm-int", &cfunPermissionInt, @src(), "(os/perm-int bytes)", "Parse a 9-character permission string and return an integer that can be used by chmod."),
            corefn.reg("os/dir", &dirImpl, @src(), "(os/dir dir &opt array)", "Iterate over files and subdirectories in a directory. Returns an array of paths parts, " ++
                "with only the file name or directory name and no prefix."),
            corefn.reg("os/stat", &statImpl, @src(), "(os/stat path &opt tab|key)", "Gets information about a file or directory. Returns a table unless the second argument is a keyword, " ++
                "in which case it returns only that field/value from stat. If the file or directory does not exist, returns nil." ++
                "The keys are:\n\n" ++
                "* :dev - the device that the file is on\n\n" ++
                "* :mode - the type of file, one of :file, :directory, :block, :character, :fifo, :socket, :link, or :other\n\n" ++
                "* :int-permissions - A Unix permission integer like 8r744\n\n" ++
                "* :permissions - A Unix permission string like \"rwxr--r--\"\n\n" ++
                "* :uid - File uid\n\n" ++
                "* :gid - File gid\n\n" ++
                "* :nlink - number of links to file\n\n" ++
                "* :rdev - Real device of file. 0 on Windows\n\n" ++
                "* :size - size of file in bytes\n\n" ++
                "* :blocks - number of blocks in file. 0 on Windows\n\n" ++
                "* :blocksize - size of blocks in file. 0 on Windows\n\n" ++
                "* :accessed - timestamp when file last accessed\n\n" ++
                "* :changed - timestamp when file last changed (permissions changed)\n\n" ++
                "* :modified - timestamp when file last modified (content changed)\n"),
            corefn.reg("os/lstat", &lstatImpl, @src(), "(os/lstat path &opt tab|key)", "Like os/stat, but don't follow symlinks.\n"),
            corefn.reg("os/chmod", &chmodImpl, @src(), "(os/chmod path mode)", "Change file permissions, where `mode` is a permission string as returned by " ++
                "`os/perm-string`, or an integer as returned by `os/perm-int`. " ++
                "When `mode` is an integer, it is interpreted as a Unix permission value, best specified in octal, like " ++
                "8r666 or 8r400. Windows will not differentiate between user, group, and other permissions, and thus will combine all of these permissions. Returns nil." ++
                "Unsupported on plan9."),
            corefn.reg("os/touch", &touchImpl, @src(), "(os/touch path &opt actime modtime)", "Update the access time and modification times for a file. By default, sets " ++
                "times to the current time."),
            corefn.reg("os/realpath", &realpathImpl, @src(), "(os/realpath path)", "Get the absolute path for a given path, following ../, ./, and symlinks. " ++
                "Returns an absolute path as a string."),
            corefn.reg("os/cd", &cdImpl, @src(), "(os/cd path)", "Change current directory to path. Returns nil on success, errors on failure."),
        };
        if (!no_umask) acc = acc ++ [_]corefn.Entry{
            corefn.reg("os/umask", &umaskImpl, @src(), "(os/umask mask)", "Set a new umask, returns the old umask."),
        };
        if (!no_symlinks) acc = acc ++ [_]corefn.Entry{
            corefn.reg("os/readlink", &readlinkImpl, @src(), "(os/readlink path)", "Read the contents of a symbolic link. Does not work on Windows.\n"),
        };
        acc = acc ++ [_]corefn.Entry{
            corefn.reg("os/mkdir", &mkdirImpl, @src(), "(os/mkdir path)", "Create a new directory. The path will be relative to the current directory if relative, otherwise " ++
                "it will be an absolute path. Returns true if the directory was created, false if the directory already exists, and " ++
                "errors otherwise."),
            corefn.reg("os/rmdir", &rmdirImpl, @src(), "(os/rmdir path)", "Delete a directory. The directory must be empty to succeed."),
            corefn.reg("os/rm", &removeImpl, @src(), "(os/rm path)", "Delete a file. Returns nil."),
            corefn.reg("os/link", &linkImpl, @src(), "(os/link oldpath newpath &opt symlink)", "Create a link at newpath that points to oldpath and returns nil. " ++
                "Iff symlink is truthy, creates a symlink. " ++
                "Iff symlink is falsey or not provided, " ++
                "creates a hard link. Does not work on Windows or Plan 9."),
            corefn.reg("os/rename", &renameImpl, @src(), "(os/rename oldname newname)", "Rename a file on disk to a new path. Returns nil."),
        };
        if (!no_symlinks) acc = acc ++ [_]corefn.Entry{
            corefn.reg("os/symlink", &symlinkImpl, @src(), "(os/symlink oldpath newpath)", "Create a symlink from oldpath to newpath, returning nil. Same as `(os/link oldpath newpath true)`."),
        };
        break :blk acc[0..acc.len].*;
    };
    return &list;
}

/// `os/open` is registered separately because it exists only under the event
/// loop, and because `janet_lib_os` lists it after the process family rather
/// than with the filesystem ones. The order of the table is observable --
/// `janet_nextmethod` walks it -- so it is preserved.
pub fn evEntries() []const corefn.Entry {
    if (!has_ev) return &.{};
    const list = comptime [_]corefn.Entry{
        corefn.reg("os/open", &openImpl, @src(), "(os/open path &opt flags mode)", "Create a stream from a file, like the POSIX open system call. Returns a new stream. " ++
            "`mode` should be a file mode as passed to `os/chmod`, but only if the create flag is given. " ++
            "The default mode is 8r666. " ++
            "Allowed flags are as follows:\n\n" ++
            "  * :r - open this file for reading\n" ++
            "  * :w - open this file for writing\n" ++
            "  * :c - create a new file (O\\_CREATE)\n" ++
            "  * :e - fail if the file exists (O\\_EXCL)\n" ++
            "  * :t - shorten an existing file to length 0 (O\\_TRUNC)\n\n" ++
            "  * :a - append to a file (O\\_APPEND on posix, FILE_APPEND_DATA on windows)\n" ++
            "Posix-only flags:\n\n" ++
            "  * :x - O\\_SYNC\n" ++
            "  * :C - O\\_NOCTTY\n\n" ++
            "  * :N - Turn off O\\_NONBLOCK and disable ev reading/writing\n\n" ++
            "Windows-only flags:\n\n" ++
            "  * :R - share reads (FILE\\_SHARE\\_READ)\n" ++
            "  * :W - share writes (FILE\\_SHARE\\_WRITE)\n" ++
            "  * :D - share deletes (FILE\\_SHARE\\_DELETE)\n" ++
            "  * :H - FILE\\_ATTRIBUTE\\_HIDDEN\n" ++
            "  * :O - FILE\\_ATTRIBUTE\\_READONLY\n" ++
            "  * :F - FILE\\_ATTRIBUTE\\_OFFLINE\n" ++
            "  * :T - FILE\\_ATTRIBUTE\\_TEMPORARY\n" ++
            "  * :d - FILE\\_FLAG\\_DELETE\\_ON\\_CLOSE\n" ++
            "  * :V - Turn off FILE\\_FLAG\\_OVERLAPPED and disable ev reading/writing\n" ++
            "  * :I - set bInheritHandle on the created file so it can be passed to other processes.\n" ++
            "  * :b - FILE\\_FLAG\\_NO\\_BUFFERING\n"),
    };
    return &list;
}
