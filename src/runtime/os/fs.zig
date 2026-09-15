//! The `os/` filesystem surface: the sixteen cfunctions with no name of their
//! own, and the host calls behind them.
//!
//! Three files once. A fourth destination, `os/fs/paths.zig`, was designed and
//! does not exist: this subtree registers nineteen `os/` cfunctions and only
//! two groups of them have a name Janet publishes, `os/stat` with `os/lstat`,
//! which share a field registry, and `os/open`, which has a type of its own.
//! Those two are the leaves beside this file. The other sixteen, `os/cwd`,
//! `os/dir`, `os/touch`, `os/realpath`, `os/link`, `os/symlink`,
//! `os/readlink`, `os/chmod`, `os/umask`, `os/mkdir`, `os/rmdir`, `os/rm`,
//! `os/cd`, `os/rename`, `os/perm-string` and `os/perm-int`, are individual
//! cfunctions, and "paths" names none of them. They are the bucket, which is
//! what a piece with no name of its own gets.
//!
//! `entries()` stays in this file because `os.zig` slices it three ways, and
//! that order is upstream Janet's `os/` registration order.
//!
//! Every platform test here goes through `builtin.os.tag`, never through a
//! translated macro. Aro, the translate-c front end, predefines `__unix__`,
//! `unix` and `__unix` for `x86_64-windows-gnu` on top of `_WIN32`, so a
//! header whose own chain tests Unix first reports POSIX in the translation
//! and Windows in the compilation of the same header for the same target. The
//! first assertion at the foot of this file is what would catch a regression.
//!
//! The host calls at the foot are the ones whose signatures name a type this
//! subsystem owns, so they stay with the type rather than moving to
//! `cabi.zig`.

// ==========================================================================
// Standard library imports
// ==========================================================================

const std = @import("std");
const builtin = @import("builtin");

// ==========================================================================
// Project imports
// ==========================================================================

const args_core = @import("../args.zig");
const arrays = @import("../value/arrays.zig");
const c = @import("cabi");
const config = @import("config");
const constants = @import("constants");
const corefn = @import("../corefn.zig");
const oa = @import("abi.zig");
const open_file = @import("fs/open.zig");
const pp_format = @import("../pp/format.zig");
const raise = @import("../../api/raise.zig");
const repr = @import("repr");
const stat = @import("fs/stat.zig");
const utils = @import("../utils.zig");
const value = @import("../value.zig");
const vm_lifecycle = @import("../vm/lifecycle.zig");
const wrap = @import("../value/helpers/wrap.zig");

/// `os/abi.zig`'s translation, which is where the Windows enumeration's
/// `_finddata_t` comes from.
const h = oa.h;

// ==========================================================================
// Constants
// ==========================================================================

/// `MAX_PATH`, which `_fullpath` takes as its buffer size.
const MAX_PATH = 260;

/// Whether this build has the event loop, which decides whether `os/open` is
/// registered at all.
pub const has_ev = config.ev;

/// The three filesystem features a build can be without. Each turns its own
/// cfunctions into a refusal rather than removing them, so a program meets a
/// message rather than a missing binding.
pub const no_realpath = !config.realpath;
pub const no_symlinks = !config.symlinks;
pub const no_umask = !config.umask;

/// Whether this target takes the Windows arm of the calls below.
const windows = builtin.os.tag == .windows;

// ==========================================================================
// Aliased types
// ==========================================================================

/// `struct utimbuf` is two `time_t` values, which is the one host structure
/// this subsystem builds rather than receiving. It is never shared across the
/// boundary: the two times cross as doubles and the structure lives only for
/// the duration of the call.
const TimeT = if (windows) i64 else std.c.time_t;

// ==========================================================================
// Types
// ==========================================================================

/// One read of a directory stream. Three outcomes rather than two, which is
/// what makes this a union and not an optional: the end of the stream and a
/// failed read are different results, and only the second leaves `errno` set.
pub const DirRead = union(enum) {
    /// The next entry that is neither "." nor "..", borrowed from the stream.
    entry: [*:0]const u8,
    /// The stream is exhausted.
    end,
    /// The read failed; `errno` describes it.
    failed,
};

// ==========================================================================
// Public functions
// ==========================================================================

/// Resolves a path to its canonical absolute form, following `.`, `..` and
/// symbolic links. The result is allocated by the host and released by the
/// caller.
pub fn canonicalPath(path: [*:0]const u8) ?[*:0]u8 {
    if (windows) return c._fullpath(null, path, MAX_PATH);
    return c.realpath(path, null);
}

/// `(os/perm-int perm)`.
pub fn cfunPermissionInt(argv: []repr.Value) raise.Error!repr.Value {
    try args_core.fixarity(argv, 1);
    return wrap.fromInteger(try stat.getUnixMode(argv, 0));
}

/// `(os/perm-string perm)`.
pub fn cfunPermissionString(argv: []repr.Value) raise.Error!repr.Value {
    try args_core.fixarity(argv, 1);
    return stat.makePermstring(try stat.getUnixMode(argv, 0));
}

/// Closes a directory stream.
pub fn dirClose(handle: *anyopaque) void {
    _ = std.c.closedir(@ptrCast(handle));
}

/// The `1` / `0` / `-1` spelling of `dirNext`, kept because
/// `test/os_fs_paths` reaches it. Nothing inside the runtime calls it:
/// `dirPosix` takes the union.
pub fn dirNextAbi(handle: *anyopaque, name_out: *[*:0]const u8) i32 {
    switch (dirNext(handle)) {
        .entry => |name| {
            name_out.* = name;
            return 1;
        },
        .end => return 0,
        .failed => return -1,
    }
}

/// Opens a directory stream, reporting failure through `errno` as `opendir`
/// does.
pub fn dirOpen(path: [*:0]const u8) ?*anyopaque {
    return @ptrCast(std.c.opendir(path));
}

/// The sixteen registrations, which `os.zig` slices three ways.
///
/// `@src()` is only valid inside a function, so a table that records its own
/// rows has to be built in one. `comptime` makes the result a compile-time
/// constant all the same, and taking its address promotes it to static
/// storage, so nothing is assembled at run time.
pub fn entries() []const corefn.Entry {
    const list = comptime blk: {
        var acc: []const corefn.Entry = &.{};
        acc = acc ++ [_]corefn.Entry{
            corefn.reg("os/cwd", &cfunCwd, @src(), "(os/cwd)", "Returns the current working directory."),
            corefn.reg("os/perm-string", &cfunPermissionString, @src(), "(os/perm-string int)", "Convert a Unix octal permission value from a permission integer as returned by `os/stat` " ++
                "to a human readable string, that follows the formatting " ++
                "of Unix tools like `ls`. Returns the string as a 9-character string of r, w, x and - characters. Does not " ++
                "include the file/directory/symlink character as rendered by `ls`."),
            corefn.reg("os/perm-int", &cfunPermissionInt, @src(), "(os/perm-int bytes)", "Parse a 9-character permission string and return an integer that can be used by chmod."),
            corefn.reg("os/dir", &cfunDir, @src(), "(os/dir dir &opt array)", "Iterate over files and subdirectories in a directory. Returns an array of paths parts, " ++
                "with only the file name or directory name and no prefix."),
            corefn.reg("os/stat", &stat.cfunStat, @src(), "(os/stat path &opt tab|key)", "Gets information about a file or directory. Returns a table unless the second argument is a keyword, " ++
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
            corefn.reg("os/lstat", &stat.cfunLstat, @src(), "(os/lstat path &opt tab|key)", "Like os/stat, but don't follow symlinks.\n"),
            corefn.reg("os/chmod", &cfunChmod, @src(), "(os/chmod path mode)", "Change file permissions, where `mode` is a permission string as returned by " ++
                "`os/perm-string`, or an integer as returned by `os/perm-int`. " ++
                "When `mode` is an integer, it is interpreted as a Unix permission value, best specified in octal, like " ++
                "8r666 or 8r400. Windows will not differentiate between user, group, and other permissions, and thus will combine all of these permissions. Returns nil." ++
                "Unsupported on plan9."),
            corefn.reg("os/touch", &cfunTouch, @src(), "(os/touch path &opt actime modtime)", "Update the access time and modification times for a file. By default, sets " ++
                "times to the current time."),
            corefn.reg("os/realpath", &cfunRealpath, @src(), "(os/realpath path)", "Get the absolute path for a given path, following ../, ./, and symlinks. " ++
                "Returns an absolute path as a string."),
            corefn.reg("os/cd", &cfunCd, @src(), "(os/cd path)", "Change current directory to path. Returns nil on success, errors on failure."),
        };
        if (!no_umask) acc = acc ++ [_]corefn.Entry{
            corefn.reg("os/umask", &cfunUmask, @src(), "(os/umask mask)", "Set a new umask, returns the old umask."),
        };
        if (!no_symlinks) acc = acc ++ [_]corefn.Entry{
            corefn.reg("os/readlink", &cfunReadlink, @src(), "(os/readlink path)", "Read the contents of a symbolic link. Does not work on Windows.\n"),
        };
        acc = acc ++ [_]corefn.Entry{
            corefn.reg("os/mkdir", &cfunMkdir, @src(), "(os/mkdir path)", "Create a new directory. The path will be relative to the current directory if relative, otherwise " ++
                "it will be an absolute path. Returns true if the directory was created, false if the directory already exists, and " ++
                "errors otherwise."),
            corefn.reg("os/rmdir", &cfunRmdir, @src(), "(os/rmdir path)", "Delete a directory. The directory must be empty to succeed."),
            corefn.reg("os/rm", &cfunRemove, @src(), "(os/rm path)", "Delete a file. Returns nil."),
            corefn.reg("os/link", &cfunLink, @src(), "(os/link oldpath newpath &opt symlink)", "Create a link at newpath that points to oldpath and returns nil. " ++
                "Iff symlink is truthy, creates a symlink. " ++
                "Iff symlink is falsey or not provided, " ++
                "creates a hard link. Does not work on Windows or Plan 9."),
            corefn.reg("os/rename", &cfunRename, @src(), "(os/rename oldname newname)", "Rename a file on disk to a new path. Returns nil."),
        };
        if (!no_symlinks) acc = acc ++ [_]corefn.Entry{
            corefn.reg("os/symlink", &cfunSymlink, @src(), "(os/symlink oldpath newpath)", "Create a symlink from oldpath to newpath, returning nil. Same as `(os/link oldpath newpath true)`."),
        };
        break :blk acc[0..acc.len].*;
    };
    return &list;
}

/// `os/open`'s registration, which is separate because it exists only under
/// the event loop, and because upstream's `os/` table lists it after the
/// process family rather than with the filesystem ones. The order of the table
/// is observable, since `nextmethod` walks it, so it is preserved.
pub fn evEntries() []const corefn.Entry {
    if (!has_ev) return &.{};
    const list = comptime [_]corefn.Entry{
        corefn.reg("os/open", &open_file.cfunOpen, @src(), "(os/open path &opt flags mode)", "Create a stream from a file, like the POSIX open system call. Returns a new stream. " ++
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

/// `link`.
pub fn hardLink(oldpath: [*:0]const u8, newpath: [*:0]const u8) i32 {
    return c.link(oldpath, newpath);
}

/// `chdir`.
pub fn hostChdir(path: [*:0]const u8) i32 {
    return if (builtin.os.tag == .windows) c._chdir(path) else c.chdir(path);
}

/// `getcwd`, into the caller's buffer.
pub fn hostGetcwd(buffer: [*]u8, size: i32) i32 {
    const result = if (builtin.os.tag == .windows)
        c._getcwd(buffer, size)
    else
        c.getcwd(buffer, @intCast(size));
    return if (result == null) -1 else 0;
}

/// `mkdir`, with the mode argument Windows does not take.
pub fn hostMkdir(path: [*:0]const u8) i32 {
    if (builtin.os.tag == .windows) return c._mkdir(path);
    return c.mkdir(path, 0o775);
}

/// `remove`.
pub fn hostRemove(path: [*:0]const u8) i32 {
    return c.remove(path);
}

/// `rename`.
pub fn hostRename(old_path: [*:0]const u8, new_path: [*:0]const u8) i32 {
    return c.rename(old_path, new_path);
}

/// `rmdir`.
pub fn hostRmdir(path: [*:0]const u8) i32 {
    return if (builtin.os.tag == .windows) c._rmdir(path) else c.rmdir(path);
}

/// Reads a link target into the caller's buffer, returning its length or -1.
/// The target is not terminated, and a target longer than the buffer is
/// truncated rather than reported, so a caller compares the length against the
/// buffer size.
pub fn readLink(path: [*:0]const u8, buffer: [*]u8, size: usize) i64 {
    return @intCast(std.c.readlink(path, buffer, size));
}

/// Whether a seconds value is inside `time_t`'s range.
///
/// The two callers that take seconds from a program ask this first. `os/sleep`
/// and `os/touch` both convert a double the caller supplied, and a conversion
/// is not a check: a NaN converts to zero, so `(os/sleep math/nan)` would
/// sleep no time at all and `(os/touch p math/nan)` would write the epoch; an
/// infinity or `1e300` converts to `time_t`'s maximum, so a sleep would hang
/// for a geological age and a timestamp would silently be something else.
/// Neither is a result to give back, and a program that means "forever" can
/// say `math/int-max`.
///
/// It is one helper rather than one check per site because it is one question.
pub fn secondsFitTimeT(x: f64) bool {
    if (!std.math.isFinite(x)) return false;
    const low: f64 = @floatFromInt(@as(TimeT, std.math.minInt(TimeT)));
    const high: f64 = @floatFromInt(@as(TimeT, std.math.maxInt(TimeT)));
    return x > low and x < high;
}

/// `symlink`.
pub fn symbolicLink(oldpath: [*:0]const u8, newpath: [*:0]const u8) i32 {
    return std.c.symlink(oldpath, newpath);
}

/// Sets a file's access and modification times, or sets both to the current
/// time when `has_times` is false.
///
/// The argument defaults are already resolved; the times arrive as doubles
/// because that is what a Janet program has. A double that no `time_t` can
/// represent saturates rather than trapping, the same way `os.zig`'s sleep
/// does.
pub fn touch(path: [*:0]const u8, has_times: bool, actime: f64, modtime: f64) i32 {
    if (!has_times) {
        return if (windows) c._utime64(path, null) else c.utime(path, null);
    }
    const times: c.utimbuf = .{
        .actime = saturatingCast(TimeT, actime),
        .modtime = saturatingCast(TimeT, modtime),
    };
    return if (windows) c._utime64(path, &times) else c.utime(path, &times);
}

// ==========================================================================
// Private functions
// ==========================================================================

/// `(os/cd path)`.
fn cfunCd(argv: []repr.Value) raise.Error!repr.Value {
    try vm_lifecycle.sandboxAssert(vm_lifecycle.Sandbox.of(&.{"fs_read"}));
    try args_core.fixarity(argv, 1);
    const path = try args_core.getCString(argv, 0);
    if (hostChdir(@ptrCast(path)) == -1) {
        return pp_format.panicf("%s: %s", .{ utils.strerrorSafe(c.errno()), path });
    }
    return wrap.fromNil();
}

/// `(os/chmod path mode)`.
fn cfunChmod(argv: []repr.Value) raise.Error!repr.Value {
    try vm_lifecycle.sandboxAssert(vm_lifecycle.Sandbox.of(&.{"fs_write"}));
    try args_core.fixarity(argv, 2);
    const path = try args_core.getCString(argv, 0);
    const mode = try stat.getMode(argv, 1);
    // WASI has no permission bits to set. The call succeeds and changes
    // nothing there, as Windows's `_chmod` ignores the bits it cannot
    // represent.
    if (builtin.os.tag == .wasi) return wrap.fromNil();
    const res = if (windows) c._chmod(@ptrCast(path), mode) else oa.chmod(@ptrCast(path), mode);
    if (res == -1) return pp_format.panicf("%s: %s", .{ utils.strerrorSafe(c.errno()), path });
    return wrap.fromNil();
}

/// `(os/cwd)`.
fn cfunCwd(argv: []repr.Value) raise.Error!repr.Value {
    try args_core.fixarity(argv, 0);
    var buf: [h.FILENAME_MAX]u8 = undefined;
    if (hostGetcwd(&buf, h.FILENAME_MAX) != 0) {
        return raise.panic("could not get current directory");
    }
    return value.fromBytes(std.mem.sliceTo(&buf, 0), .string);
}

/// `(os/dir path &opt array)`.
fn cfunDir(argv: []repr.Value) raise.Error!repr.Value {
    try vm_lifecycle.sandboxAssert(vm_lifecycle.Sandbox.of(&.{"fs_read"}));
    try args_core.arity(argv, 1, 2);
    const dir = try args_core.getCString(argv, 0);
    const paths = if (argv.len == 2) try args_core.getArray(argv, 1) else arrays.new(0);
    if (windows) try dirWindows(dir, paths) else try dirPosix(dir, paths);
    return wrap.fromArray(paths);
}

/// `(os/link oldpath newpath &opt symlink)`.
fn cfunLink(argv: []repr.Value) raise.Error!repr.Value {
    try vm_lifecycle.sandboxAssert(vm_lifecycle.Sandbox.of(&.{"fs_write"}));
    try args_core.arity(argv, 2, 3);
    if (windows) return raise.panic("not supported on Windows or Plan 9");
    const oldpath = try args_core.getCString(argv, 0);
    const newpath = try args_core.getCString(argv, 1);
    const symbolic = argv.len == 3 and repr.truthy(argv[2]);
    const res = if (symbolic)
        symlinkOrLink(@ptrCast(oldpath), @ptrCast(newpath))
    else
        hardLink(@ptrCast(oldpath), @ptrCast(newpath));
    if (res == -1) {
        return pp_format.panicf("%s: %s -> %s", .{ utils.strerrorSafe(c.errno()), oldpath, newpath });
    }
    return wrap.fromNil();
}

/// `(os/mkdir path)`.
fn cfunMkdir(argv: []repr.Value) raise.Error!repr.Value {
    try vm_lifecycle.sandboxAssert(vm_lifecycle.Sandbox.of(&.{"fs_write"}));
    try args_core.fixarity(argv, 1);
    const path = try args_core.getCString(argv, 0);
    const res = hostMkdir(@ptrCast(path));
    if (res == 0) return wrap.fromTrue();
    if (c.errno() == h.EEXIST) return wrap.fromFalse();
    return pp_format.panicf("%s: %s", .{ utils.strerrorSafe(c.errno()), path });
}

/// `(os/readlink path)`. Like `os/rm`, this asserts a sandbox permission
/// before anything else, and its is filesystem read.
fn cfunReadlink(argv: []repr.Value) raise.Error!repr.Value {
    try vm_lifecycle.sandboxAssert(vm_lifecycle.Sandbox.of(&.{"fs_read"}));
    try args_core.fixarity(argv, 1);
    if (windows) return raise.panic("not supported on Windows");
    var buffer: [oa.path_max]u8 = undefined;
    const path = try args_core.getCString(argv, 0);
    const len = readLink(@ptrCast(path), &buffer, buffer.len);
    if (len < 0 or @as(usize, @intCast(len)) >= buffer.len) {
        return pp_format.panicf("%s: %s", .{ utils.strerrorSafe(c.errno()), path });
    }
    return value.fromBytes(buffer[0..@intCast(len)], .string);
}

/// `(os/realpath path)`.
fn cfunRealpath(argv: []repr.Value) raise.Error!repr.Value {
    try vm_lifecycle.sandboxAssert(vm_lifecycle.Sandbox.of(&.{"fs_read"}));
    try args_core.fixarity(argv, 1);
    const src = try args_core.getCString(argv, 0);
    if (no_realpath) return raise.panic("os/realpath not enabled for this platform");
    const dest = canonicalPath(@ptrCast(src)) orelse {
        return pp_format.panicf("%s: %s", .{ utils.strerrorSafe(c.errno()), src });
    };
    // The host allocated it, so the host's `free` releases it, and the
    // release is a `defer` because the interning below can raise and the
    // Windows arm raises on its own account.
    defer utils.free(dest);
    const ret = value.fromBytes(std.mem.span(dest), .string);
    if (windows) {
        if (c.GetFileAttributesA(dest) == 0xFFFF_FFFF) {
            return pp_format.panicf("path does not exist: %v", .{ret});
        }
    }
    return ret;
}

/// `(os/rm path)`.
///
/// Every filesystem entry point asserts the capability its operation needs,
/// and this is one of the two that once did not. `os/mkdir`, `os/rmdir`,
/// `os/cd`, `os/rename`, `os/touch`, `os/chmod`, `os/umask`, `os/link` and
/// `os/symlink` all assert filesystem write; without the line below, a program
/// under a full filesystem sandbox could still delete any file the process
/// could reach. `os/readlink` is the other, and asserts filesystem read.
///
/// The assertion goes before the arity check, which is the order all nine
/// neighbours use and which a program can observe.
fn cfunRemove(argv: []repr.Value) raise.Error!repr.Value {
    try vm_lifecycle.sandboxAssert(vm_lifecycle.Sandbox.of(&.{"fs_write"}));
    try args_core.fixarity(argv, 1);
    const path = try args_core.getCString(argv, 0);
    if (hostRemove(@ptrCast(path)) == -1) {
        return pp_format.panicf("%s: %s", .{ utils.strerrorSafe(c.errno()), path });
    }
    return wrap.fromNil();
}

/// `(os/rename oldpath newpath)`. The one failure message in this family that
/// is the bare `strerror` text rather than a `%s: %s` naming the path.
fn cfunRename(argv: []repr.Value) raise.Error!repr.Value {
    try vm_lifecycle.sandboxAssert(vm_lifecycle.Sandbox.of(&.{"fs_write"}));
    try args_core.fixarity(argv, 2);
    const src = try args_core.getCString(argv, 0);
    const dest = try args_core.getCString(argv, 1);
    if (hostRename(@ptrCast(src), @ptrCast(dest)) != 0) {
        return raise.panic(@ptrCast(utils.strerrorSafe(c.errno())));
    }
    return wrap.fromNil();
}

/// `(os/rmdir path)`.
fn cfunRmdir(argv: []repr.Value) raise.Error!repr.Value {
    try vm_lifecycle.sandboxAssert(vm_lifecycle.Sandbox.of(&.{"fs_write"}));
    try args_core.fixarity(argv, 1);
    const path = try args_core.getCString(argv, 0);
    if (hostRmdir(@ptrCast(path)) == -1) {
        return pp_format.panicf("%s: %s", .{ utils.strerrorSafe(c.errno()), path });
    }
    return wrap.fromNil();
}

/// `(os/symlink oldpath newpath)`.
fn cfunSymlink(argv: []repr.Value) raise.Error!repr.Value {
    try vm_lifecycle.sandboxAssert(vm_lifecycle.Sandbox.of(&.{"fs_write"}));
    try args_core.fixarity(argv, 2);
    if (windows) return raise.panic("not supported on Windows or Plan 9");
    const oldpath = try args_core.getCString(argv, 0);
    const newpath = try args_core.getCString(argv, 1);
    if (symlinkOrLink(@ptrCast(oldpath), @ptrCast(newpath)) == -1) {
        return pp_format.panicf("%s: %s -> %s", .{ utils.strerrorSafe(c.errno()), oldpath, newpath });
    }
    return wrap.fromNil();
}

/// `(os/touch path &opt actime modtime)`.
fn cfunTouch(argv: []repr.Value) raise.Error!repr.Value {
    try vm_lifecycle.sandboxAssert(vm_lifecycle.Sandbox.of(&.{"fs_write"}));
    try args_core.arity(argv, 1, 3);
    const path = try args_core.getCString(argv, 0);
    var actime: f64 = 0;
    var modtime: f64 = 0;
    if (argv.len >= 2) {
        actime = try args_core.getNumber(argv, 1);
        modtime = if (argv.len >= 3) try args_core.getNumber(argv, 2) else actime;
        if (!secondsFitTimeT(actime) or !secondsFitTimeT(modtime)) {
            return raise.panic("invalid argument to touch");
        }
    }
    if (touch(@ptrCast(path), argv.len >= 2, actime, modtime) == -1) {
        return raise.panic(@ptrCast(utils.strerrorSafe(c.errno())));
    }
    return wrap.fromNil();
}

/// `(os/umask mask)`.
fn cfunUmask(argv: []repr.Value) raise.Error!repr.Value {
    try vm_lifecycle.sandboxAssert(vm_lifecycle.Sandbox.of(&.{"fs_write"}));
    try args_core.fixarity(argv, 1);
    const mask = try stat.getMode(argv, 0);
    const res = if (windows) c._umask(mask) else oa.umask(mask);
    return wrap.fromInteger(stat.hostPermToUnix(@intCast(res)));
}

/// Reports the next entry that is neither "." nor "..", borrowing the name
/// from the directory stream.
///
/// The C loop this replaces cleared `errno` before each read, because a null
/// result means either the end of the stream or a failure.
fn dirNext(handle: *anyopaque) DirRead {
    while (true) {
        c.setErrno(0);
        const name = readEntryName(handle) orelse {
            return if (c.errno() != 0) .failed else .end;
        };
        if (isDotEntry(name)) continue;
        return .{ .entry = name };
    }
}

/// Reads the next entry from a directory stream and returns its name, or null
/// at the end of the stream or on a failure.
///
/// `std.c` types a WASI `readdir` result as `*void`, so on WASI the entry is
/// read through `os/abi.h`'s `struct dirent`.
inline fn readEntryName(handle: *anyopaque) ?[*:0]const u8 {
    if (builtin.os.tag == .wasi) {
        const entry = h.readdir(@ptrCast(handle));
        if (entry == null) return null;
        return @ptrCast(h.wattle_dirent_name(entry));
    } else {
        const entry = std.c.readdir(@ptrCast(handle)) orelse return null;
        return @ptrCast(&entry.name);
    }
}

/// The POSIX enumeration, through an explicit iterator. The close-then-panic
/// on a failed read is the C original's, and the errno is saved across the
/// close because closing can overwrite it.
fn dirPosix(dir: [*]const u8, paths: *arrays.Array) raise.Error!void {
    const dfd = dirOpen(@ptrCast(dir)) orelse {
        return pp_format.panicf("cannot open directory %s: %s", .{ dir, utils.strerrorSafe(c.errno()) });
    };
    while (true) {
        switch (dirNext(dfd)) {
            .failed => {
                const olderr = c.errno();
                dirClose(dfd);
                return pp_format.panicf("failed to read directory %s: %s", .{ dir, utils.strerrorSafe(olderr) });
            },
            .end => break,
            .entry => |name| try arrays.push(paths, value.fromBytes(std.mem.span(name), .string)),
        }
    }
    dirClose(dfd);
}

/// The Windows enumeration, written here rather than left in C: `_finddata_t`
/// translates completely on mingw, which the design note for a separate paths
/// file had assumed it would not.
fn dirWindows(dir: [*]const u8, paths: *arrays.Array) raise.Error!void {
    var afile: h._finddata_t = undefined;
    var pattern: [h.MAX_PATH + 1]u8 = undefined;
    const dirlen = std.mem.len(@as([*:0]const u8, @ptrCast(dir)));
    if (dirlen > pattern.len - 3) return pp_format.panicf("path too long: %s", .{dir});
    _ = std.fmt.bufPrintZ(&pattern, "{s}/*", .{@as([*:0]const u8, @ptrCast(dir))}) catch unreachable;
    const res = h._findfirst(&pattern, &afile);
    if (res == -1) return raise.panicv(value.fromBytes(std.mem.span(utils.strerrorSafe(c.errno())), .string));
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

/// Whether a directory entry is "." or "..", matching neither a longer name
/// that starts with a dot nor the empty name.
fn isDotEntry(name: [*:0]const u8) bool {
    if (name[0] != '.') return false;
    if (name[1] == 0) return true;
    return name[1] == '.' and name[2] == 0;
}

/// Converts toward zero, clamping instead of trapping. This reproduces the
/// AArch64 conversion the C implementation performs without a sanitizer: a NaN
/// becomes zero and an out-of-range value becomes the nearest bound. A NaN is
/// separated first because `@intFromFloat` is illegal for it and because the
/// ordinary comparisons below would otherwise send it to the low bound.
///
/// Every remaining caller has already established its argument's range, and
/// `secondsFitTimeT` above is what the two that take one from a program use.
fn saturatingCast(comptime T: type, x: f64) T {
    if (std.math.isNan(x)) return 0;
    const low: f64 = @floatFromInt(@as(T, std.math.minInt(T)));
    const high: f64 = @floatFromInt(@as(T, std.math.maxInt(T)));
    if (!(x > low)) return std.math.minInt(T);
    if (x >= high) return std.math.maxInt(T);
    return @intFromFloat(x);
}

/// Where the symbolic-link entry points do not exist, `os/link`'s `symlink`
/// argument silently makes a hard link instead. That is what a Janet program
/// sees, and the choice is written out here so that the entry point and the
/// helper cannot disagree about which function is called.
inline fn symlinkOrLink(old: [*:0]const u8, new: [*:0]const u8) i32 {
    return if (no_symlinks) hardLink(old, new) else symbolicLink(old, new);
}

// ==========================================================================
// Tests
// ==========================================================================

comptime {
    if ((builtin.os.tag == .windows) and !windows)
        @compileError("platform tests must not read a translated platform macro");
}

comptime {
    if (has_ev != (constants.JANET_VM_HAS_EV != 0))
        @compileError("config.ev disagrees with constants' restatement of it");
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
