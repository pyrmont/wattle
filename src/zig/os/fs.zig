//! The `os/` filesystem surface: the sixteen cfunctions with no name of their
//! own, and the host calls behind them.
//!
//! `os_files.zig` plus `os_fs.zig` and `os_fs_paths.zig` until Phase 12
//! increment 6f. `port/TREE.md` had a fifth destination here, `os/fs/paths.zig`,
//! and it does not exist: **this subtree registers nineteen `os/` cfunctions
//! and only two groups of them have a name Janet publishes** -- `os/stat` with
//! `os/lstat`, which share a field registry, and `os/open`, which has a type of
//! its own. Those two are the leaves beside this file. The other sixteen --
//! `os/cwd`, `os/dir`, `os/touch`, `os/realpath`, `os/link`, `os/symlink`,
//! `os/readlink`, `os/chmod`, `os/umask`, `os/mkdir`, `os/rmdir`, `os/rm`,
//! `os/cd`, `os/rename`, `os/perm-string`, `os/perm-int` -- are individual
//! cfunctions, and "paths" names none of them. They are the bucket, which is
//! what the heuristic says a piece with no name of its own gets.
//!
//! **Fourteen seam entries went with the merge.** Six were `export fn` and
//! became `hostGetcwd` and its neighbours, symbols intact; the other eight were
//! already Zig-named by increment 5d and only the `extern fn` declarations here
//! had to go. `entries()` stays in this file because `os.zig` slices it three
//! ways and that order is `janet_lib_os`'s own.

const std = @import("std");
const builtin = @import("builtin");
const types = @import("types");
const constants = @import("constants");
const c = @import("cabi");
const raise = @import("raise");
const corefn = @import("corefn");
const config = @import("config");
const oa = @import("abi.zig");
const args_core = @import("../args.zig");
const arrays = @import("../value/arrays.zig");
const tables = @import("../value/tables.zig");
const kind = @import("../value/helpers/kind.zig");
const wrap = @import("../value/helpers/wrap.zig");
const pp_format = @import("../pp/format.zig");
const ev_loop = @import("../ev.zig");
const vm_lifecycle = @import("../vm/lifecycle.zig");
const host_stat = @import("fs/host_stat.zig");
const stat = @import("fs/stat.zig");
const value = @import("../value.zig");
const open_file = @import("fs/open.zig");

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
    if ((builtin.os.tag == .windows) and !windows)
        @compileError("platform tests must not read janet.h's derived macros");
}

pub const no_symlinks = !config.symlinks;
pub const no_realpath = !config.realpath;
pub const no_umask = !config.umask;
pub const has_ev = config.ev;

comptime {
    if (has_ev != (constants.JANET_VM_HAS_EV != 0))
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

/// `src/core/util.h`, declared here rather than in `cabi.zig`.
extern fn janet_strerror(e: c_int) callconv(.c) [*:0]const u8;

/// `janet_wrap_integer`, written out rather than called. `janet.h` declares the
/// function beside its macro and `wrap.c` defines it only for the two nanbox
/// layouts, so a tagged build has no such symbol and a Zig caller -- which
/// cannot use the macro -- does not link. `marsh.zig`, `pp_pretty.zig` and
/// `value_access.zig` write it out for the same reason, and `FOUND.md` has the
/// defect. This is the fourth subsystem to meet it.
inline fn wrapInteger(x: i32) types.Janet {
    return wrap.fromNumber(@floatFromInt(x));
}

inline fn errno() c_int {
    return std.c._errno().*;
}

pub fn cfunPermissionString(argv: []types.Janet) align(corefn.alignment) raise.Raising(types.Janet) {
    try args_core.fixarity(argv, 1);
    return stat.makePermstring(try stat.getUnixMode(argv, 0));
}

pub fn cfunPermissionInt(argv: []types.Janet) align(corefn.alignment) raise.Raising(types.Janet) {
    try args_core.fixarity(argv, 1);
    return wrapInteger(try stat.getUnixMode(argv, 0));
}

// ==========================================================================
// Basic filesystem operations
// ==========================================================================

fn cwdImpl(argv: []types.Janet) raise.Raising(types.Janet) {
    try args_core.fixarity(argv, 0);
    var buf: [h.FILENAME_MAX]u8 = undefined;
    if (hostGetcwd(&buf, h.FILENAME_MAX) != 0) {
        return raise.panic("could not get current directory");
    }
    return value.fromBytes(std.mem.sliceTo(&buf, 0), .string);
}

fn mkdirImpl(argv: []types.Janet) raise.Raising(types.Janet) {
    try vm_lifecycle.sandboxAssert(constants.JANET_SANDBOX_FS_WRITE);
    try args_core.fixarity(argv, 1);
    const path = try args_core.getCString(argv, 0);
    const res = hostMkdir(@ptrCast(path));
    if (res == 0) return wrap.fromTrue();
    if (errno() == h.EEXIST) return wrap.fromFalse();
    return pp_format.panicf("%s: %s", .{ janet_strerror(errno()), path });
}

fn rmdirImpl(argv: []types.Janet) raise.Raising(types.Janet) {
    try vm_lifecycle.sandboxAssert(constants.JANET_SANDBOX_FS_WRITE);
    try args_core.fixarity(argv, 1);
    const path = try args_core.getCString(argv, 0);
    if (hostRmdir(@ptrCast(path)) == -1) {
        return pp_format.panicf("%s: %s", .{ janet_strerror(errno()), path });
    }
    return wrap.fromNil();
}

fn cdImpl(argv: []types.Janet) raise.Raising(types.Janet) {
    try vm_lifecycle.sandboxAssert(constants.JANET_SANDBOX_FS_READ);
    try args_core.fixarity(argv, 1);
    const path = try args_core.getCString(argv, 0);
    if (hostChdir(@ptrCast(path)) == -1) {
        return pp_format.panicf("%s: %s", .{ janet_strerror(errno()), path });
    }
    return wrap.fromNil();
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
fn removeImpl(argv: []types.Janet) raise.Raising(types.Janet) {
    try vm_lifecycle.sandboxAssert(constants.JANET_SANDBOX_FS_WRITE);
    try args_core.fixarity(argv, 1);
    const path = try args_core.getCString(argv, 0);
    if (hostRemove(@ptrCast(path)) == -1) {
        return pp_format.panicf("%s: %s", .{ janet_strerror(errno()), path });
    }
    return wrap.fromNil();
}

/// The one failure message in this family that is a bare `janet_panic` over
/// `janet_strerror` rather than a `%s: %s` naming the path. Reproduced.
fn renameImpl(argv: []types.Janet) raise.Raising(types.Janet) {
    try vm_lifecycle.sandboxAssert(constants.JANET_SANDBOX_FS_WRITE);
    try args_core.fixarity(argv, 2);
    const src = try args_core.getCString(argv, 0);
    const dest = try args_core.getCString(argv, 1);
    if (hostRename(@ptrCast(src), @ptrCast(dest)) != 0) {
        return raise.panic(@ptrCast(janet_strerror(errno())));
    }
    return wrap.fromNil();
}

fn touchImpl(argv: []types.Janet) raise.Raising(types.Janet) {
    try vm_lifecycle.sandboxAssert(constants.JANET_SANDBOX_FS_WRITE);
    try args_core.arity(argv, 1, 3);
    const path = try args_core.getCString(argv, 0);
    var actime: f64 = 0;
    var modtime: f64 = 0;
    if (@as(i32, @intCast(argv.len)) >= 2) {
        actime = try args_core.getNumber(argv, 1);
        modtime = if (@as(i32, @intCast(argv.len)) >= 3) try args_core.getNumber(argv, 2) else actime;
    }
    if (touch(@ptrCast(path), @intFromBool(@as(i32, @intCast(argv.len)) >= 2), actime, modtime) == -1) {
        return raise.panic(@ptrCast(janet_strerror(errno())));
    }
    return wrap.fromNil();
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
    return if (no_symlinks) hardLink(old, new) else symbolicLink(old, new);
}

fn linkImpl(argv: []types.Janet) raise.Raising(types.Janet) {
    try vm_lifecycle.sandboxAssert(constants.JANET_SANDBOX_FS_WRITE);
    try args_core.arity(argv, 2, 3);
    if (windows) return raise.panic("not supported on Windows or Plan 9");
    const oldpath = try args_core.getCString(argv, 0);
    const newpath = try args_core.getCString(argv, 1);
    const symbolic = @as(i32, @intCast(argv.len)) == 3 and kind.truthy(argv[2]) != 0;
    const res = if (symbolic)
        symlinkOrLink(@ptrCast(oldpath), @ptrCast(newpath))
    else
        hardLink(@ptrCast(oldpath), @ptrCast(newpath));
    if (res == -1) {
        return pp_format.panicf("%s: %s -> %s", .{ janet_strerror(errno()), oldpath, newpath });
    }
    return wrap.fromNil();
}

fn symlinkImpl(argv: []types.Janet) raise.Raising(types.Janet) {
    try vm_lifecycle.sandboxAssert(constants.JANET_SANDBOX_FS_WRITE);
    try args_core.fixarity(argv, 2);
    if (windows) return raise.panic("not supported on Windows or Plan 9");
    const oldpath = try args_core.getCString(argv, 0);
    const newpath = try args_core.getCString(argv, 1);
    if (symlinkOrLink(@ptrCast(oldpath), @ptrCast(newpath)) == -1) {
        return pp_format.panicf("%s: %s -> %s", .{ janet_strerror(errno()), oldpath, newpath });
    }
    return wrap.fromNil();
}

/// Like `os/rm`, this one asserts no sandbox permission.
fn readlinkImpl(argv: []types.Janet) raise.Raising(types.Janet) {
    try args_core.fixarity(argv, 1);
    if (windows) return raise.panic("not supported on Windows");
    var buffer: [oa.path_max]u8 = undefined;
    const path = try args_core.getCString(argv, 0);
    const len = readLink(@ptrCast(path), &buffer, buffer.len);
    if (len < 0 or @as(usize, @intCast(len)) >= buffer.len) {
        return pp_format.panicf("%s: %s", .{ janet_strerror(errno()), path });
    }
    return value.fromBytes(buffer[0..@intCast(len)], .string);
}

/// The host allocates the path and this frees it, on the POSIX/Windows split
/// `FOUND.md` records: `canonicalPath` is `realpath` on POSIX and
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

fn realpathImpl(argv: []types.Janet) raise.Raising(types.Janet) {
    try vm_lifecycle.sandboxAssert(constants.JANET_SANDBOX_FS_READ);
    try args_core.fixarity(argv, 1);
    const src = try args_core.getCString(argv, 0);
    if (no_realpath) return raise.panic("os/realpath not enabled for this platform");
    const dest = canonicalPath(@ptrCast(src)) orelse {
        return pp_format.panicf("%s: %s", .{ janet_strerror(errno()), src });
    };
    const ret = value.fromBytes(std.mem.span(dest), .string);
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
fn dirWindows(dir: [*]const u8, paths: *types.JanetArray) raise.Raising(void) {
    var afile: h._finddata_t = undefined;
    var pattern: [h.MAX_PATH + 1]u8 = undefined;
    const dirlen = std.mem.len(@as([*:0]const u8, @ptrCast(dir)));
    if (dirlen > pattern.len - 3) return pp_format.panicf("path too long: %s", .{dir});
    _ = std.fmt.bufPrintZ(&pattern, "{s}/*", .{@as([*:0]const u8, @ptrCast(dir))}) catch unreachable;
    const res = h._findfirst(&pattern, &afile);
    if (res == -1) return raise.panicv(value.fromBytes(std.mem.span(janet_strerror(errno())), .string));
    while (true) {
        const name: [*:0]const u8 = @ptrCast(&afile.name);
        if (!std.mem.eql(u8, std.mem.span(name), ".") and
            !std.mem.eql(u8, std.mem.span(name), ".."))
        {
            try arrays.push(paths, value.fromBytes(std.mem.span(name), .string));
        }
        if (h._findnext(res, &afile) == -1) break;
    }
    _ = h._findclose(res);
}

/// The POSIX enumeration, through `-Dos-fs-paths`'s explicit iterator. The
/// close-then-panic on a failed read is the C original's, and the errno is
/// saved across the close because closing can overwrite it.
fn dirPosix(dir: [*]const u8, paths: *types.JanetArray) raise.Raising(void) {
    const dfd = dirOpen(@ptrCast(dir)) orelse {
        return pp_format.panicf("cannot open directory %s: %s", .{ dir, janet_strerror(errno()) });
    };
    while (true) {
        var name: [*:0]const u8 = undefined;
        const status = dirNext(dfd, &name);
        if (status < 0) {
            const olderr = errno();
            dirClose(dfd);
            return pp_format.panicf("failed to read directory %s: %s", .{ dir, janet_strerror(olderr) });
        }
        if (status == 0) break;
        try arrays.push(paths, value.fromBytes(std.mem.span(name), .string));
    }
    dirClose(dfd);
}

fn dirImpl(argv: []types.Janet) raise.Raising(types.Janet) {
    try vm_lifecycle.sandboxAssert(constants.JANET_SANDBOX_FS_READ);
    try args_core.arity(argv, 1, 2);
    const dir = try args_core.getCString(argv, 0);
    const paths = if (@as(i32, @intCast(argv.len)) == 2) try args_core.getArray(argv, 1) else arrays.new(0);
    if (windows) try dirWindows(dir, paths) else try dirPosix(dir, paths);
    return wrap.fromArray(paths);
}

extern fn chmod(path: [*:0]const u8, mode: stat.jmode_t) callconv(.c) c_int;
extern fn _chmod(path: [*:0]const u8, mode: c_int) callconv(.c) c_int;
extern fn umask(mask: stat.jmode_t) callconv(.c) stat.jmode_t;
extern fn _umask(mask: c_int) callconv(.c) c_int;

fn chmodImpl(argv: []types.Janet) raise.Raising(types.Janet) {
    try vm_lifecycle.sandboxAssert(constants.JANET_SANDBOX_FS_WRITE);
    try args_core.fixarity(argv, 2);
    const path = try args_core.getCString(argv, 0);
    const mode = try stat.getMode(argv, 1);
    const res = if (windows) _chmod(@ptrCast(path), mode) else chmod(@ptrCast(path), mode);
    if (res == -1) return pp_format.panicf("%s: %s", .{ janet_strerror(errno()), path });
    return wrap.fromNil();
}

fn umaskImpl(argv: []types.Janet) raise.Raising(types.Janet) {
    try vm_lifecycle.sandboxAssert(constants.JANET_SANDBOX_FS_WRITE);
    try args_core.fixarity(argv, 1);
    const mask = try stat.getMode(argv, 0);
    const res = if (windows) _umask(mask) else umask(mask);
    return wrapInteger(stat.hostPermToUnix(@intCast(res)));
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
            corefn.reg("os/stat", &stat.statImpl, @src(), "(os/stat path &opt tab|key)", "Gets information about a file or directory. Returns a table unless the second argument is a keyword, " ++
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
            corefn.reg("os/lstat", &stat.lstatImpl, @src(), "(os/lstat path &opt tab|key)", "Like os/stat, but don't follow symlinks.\n"),
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
        corefn.reg("os/open", &open_file.openImpl, @src(), "(os/open path &opt flags mode)", "Create a stream from a file, like the POSIX open system call. Returns a new stream. " ++
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

extern fn getcwd(buffer: [*]u8, size: usize) callconv(.c) ?[*]u8;
extern fn _getcwd(buffer: [*]u8, size: c_int) callconv(.c) ?[*]u8;
extern fn mkdir(path: [*:0]const u8, mode: c_uint) callconv(.c) c_int;
extern fn _mkdir(path: [*:0]const u8) callconv(.c) c_int;
extern fn rmdir(path: [*:0]const u8) callconv(.c) c_int;
extern fn _rmdir(path: [*:0]const u8) callconv(.c) c_int;
extern fn chdir(path: [*:0]const u8) callconv(.c) c_int;
extern fn _chdir(path: [*:0]const u8) callconv(.c) c_int;
extern fn remove(path: [*:0]const u8) callconv(.c) c_int;
extern fn rename(old_path: [*:0]const u8, new_path: [*:0]const u8) callconv(.c) c_int;

pub fn hostGetcwd(buffer: [*]u8, size: i32) i32 {
    const result = if (builtin.os.tag == .windows)
        _getcwd(buffer, size)
    else
        getcwd(buffer, @intCast(size));
    return if (result == null) -1 else 0;
}

pub fn hostMkdir(path: [*:0]const u8) i32 {
    if (builtin.os.tag == .windows) return _mkdir(path);
    return mkdir(path, 0o775);
}

pub fn hostRmdir(path: [*:0]const u8) i32 {
    return if (builtin.os.tag == .windows) _rmdir(path) else rmdir(path);
}

pub fn hostChdir(path: [*:0]const u8) i32 {
    return if (builtin.os.tag == .windows) _chdir(path) else chdir(path);
}

pub fn hostRemove(path: [*:0]const u8) i32 {
    return remove(path);
}

pub fn hostRename(old_path: [*:0]const u8, new_path: [*:0]const u8) i32 {
    return rename(old_path, new_path);
}

/// `struct utimbuf` is two `time_t` values, which is the one host structure
/// this subsystem builds rather than receiving. It is never shared across the
/// boundary: C passes the two times as doubles and the structure lives only for
/// the duration of the call.
const TimeT = if (windows) i64 else std.c.time_t;
const utimbuf = extern struct {
    actime: TimeT,
    modtime: TimeT,
};

extern fn link(oldpath: [*:0]const u8, newpath: [*:0]const u8) callconv(.c) c_int;
extern fn utime(path: [*:0]const u8, times: ?*const utimbuf) callconv(.c) c_int;
extern fn realpath(path: [*:0]const u8, resolved: ?[*]u8) callconv(.c) ?[*:0]u8;

/// The MinGW CRT resolves `utime` to the 64-bit variant, which is what Janet's
/// C implementation calls.
extern fn _utime64(path: [*:0]const u8, times: ?*const utimbuf) callconv(.c) c_int;
extern fn _fullpath(resolved: ?[*]u8, path: [*:0]const u8, size: c_int) callconv(.c) ?[*:0]u8;

const MAX_PATH = 260;

comptime {
    if (!windows) {}
}

/// Open a directory stream, reporting failure through `errno` as `opendir`
/// does.
pub fn dirOpen(path: [*:0]const u8) ?*anyopaque {
    return @ptrCast(std.c.opendir(path));
}

/// Report the next entry that is neither "." nor "..", borrowing the name from
/// the directory stream.
///
/// Returns 1 with a name, 0 at the end of the stream, or -1 with `errno` set.
/// The C loop this replaces cleared `errno` before each read, because a null
/// result means either the end of the stream or a failure.
fn dirNextImpl(handle: *anyopaque, name_out: *[*:0]const u8) raise.Raising(i32) {
    const dir: *std.c.DIR = @ptrCast(handle);
    while (true) {
        std.c._errno().* = 0;
        const entry = std.c.readdir(dir) orelse {
            return if (std.c._errno().* != 0) -1 else 0;
        };
        const name: [*:0]const u8 = @ptrCast(&entry.name);
        if (isDotEntry(name)) continue;
        name_out.* = name;
        return 1;
    }
}

pub fn dirNext(handle: *anyopaque, name_out: *[*:0]const u8) i32 {
    return raise.reported(dirNextImpl(handle, name_out));
}

pub fn dirClose(handle: *anyopaque) void {
    _ = std.c.closedir(@ptrCast(handle));
}

fn isDotEntry(name: [*:0]const u8) bool {
    if (name[0] != '.') return false;
    if (name[1] == 0) return true;
    return name[1] == '.' and name[2] == 0;
}

pub fn hardLink(oldpath: [*:0]const u8, newpath: [*:0]const u8) i32 {
    return link(oldpath, newpath);
}

pub fn symbolicLink(oldpath: [*:0]const u8, newpath: [*:0]const u8) i32 {
    return std.c.symlink(oldpath, newpath);
}

/// Read a link target into the caller's buffer, returning its length or -1.
/// The target is not terminated, and a target longer than the buffer is
/// truncated rather than reported, which is why C compares the length against
/// the buffer size.
pub fn readLink(path: [*:0]const u8, buffer: [*]u8, size: usize) i64 {
    return @intCast(std.c.readlink(path, buffer, size));
}

/// Set a file's access and modification times, or set both to the current time
/// when `has_times` is zero.
///
/// C has already resolved the argument defaults; the times arrive as doubles
/// because that is what Janet holds. Converting a double that no `time_t` can
/// represent is undefined in C, so the port saturates instead, as the host wait
/// in `os_time.zig` does.
pub fn touch(path: [*:0]const u8, has_times: i32, actime: f64, modtime: f64) i32 {
    if (has_times == 0) {
        return if (windows) _utime64(path, null) else utime(path, null);
    }
    const times: utimbuf = .{
        .actime = saturatingCast(TimeT, actime),
        .modtime = saturatingCast(TimeT, modtime),
    };
    return if (windows) _utime64(path, &times) else utime(path, &times);
}

/// Resolve a path to its canonical absolute form, following `.`, `..`, and
/// symbolic links. The result is allocated by the host and released by the
/// caller.
pub fn canonicalPath(path: [*:0]const u8) ?[*:0]u8 {
    if (windows) return _fullpath(null, path, MAX_PATH);
    return realpath(path, null);
}

/// Convert toward zero, clamping instead of trapping. This reproduces the
/// AArch64 conversion the C implementation performs without a sanitizer: a NaN
/// becomes zero and an out-of-range value becomes the nearest bound. A NaN is
/// separated first because `@intFromFloat` is illegal for it and because the
/// ordinary comparisons below would otherwise send it to the low bound.
fn saturatingCast(comptime T: type, x: f64) T {
    if (std.math.isNan(x)) return 0;
    const low: f64 = @floatFromInt(@as(T, std.math.minInt(T)));
    const high: f64 = @floatFromInt(@as(T, std.math.maxInt(T)));
    if (!(x > low)) return std.math.minInt(T);
    if (x >= high) return std.math.maxInt(T);
    return @intFromFloat(x);
}

test "dot entries are recognized without matching longer names" {
    try std.testing.expect(isDotEntry("."));
    try std.testing.expect(isDotEntry(".."));
    try std.testing.expect(!isDotEntry("..."));
    try std.testing.expect(!isDotEntry(".hidden"));
    try std.testing.expect(!isDotEntry("first"));
    try std.testing.expect(!isDotEntry(""));
}

test "saturating conversion clamps rather than trapping" {
    try std.testing.expectEqual(@as(i64, 0), saturatingCast(i64, std.math.nan(f64)));
    try std.testing.expectEqual(@as(i64, 1000000000), saturatingCast(i64, 1000000000.75));
    try std.testing.expectEqual(@as(i64, -1), saturatingCast(i64, -1.5));
    try std.testing.expectEqual(@as(i64, std.math.maxInt(i64)), saturatingCast(i64, 1e300));
    try std.testing.expectEqual(@as(i64, std.math.minInt(i64)), saturatingCast(i64, -1e300));
}
