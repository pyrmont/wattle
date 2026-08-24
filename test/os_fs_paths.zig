//! Behavioral contract for directory enumeration, links, timestamps and
//! canonical paths — the kernels behind `os/dir`, `os/link`, `os/symlink`,
//! `os/readlink`, `os/touch` and `os/realpath`.
//!
//! ## What only the kernels can be asked
//!
//! Each of these has a shape at the C level that the Janet function smooths
//! over, and the smoothing is where a port goes wrong:
//!
//!   - **enumeration is a three-call protocol** — open, next until it answers
//!     zero, close — and `next` must skip `.` and `..` itself. `os/dir`
//!     returns a finished array, so nothing above can tell a skipped entry
//!     from one that was never produced.
//!   - **`readlink` truncates rather than failing** when the buffer is too
//!     short, and answers the length written. That is what the caller's
//!     "length reached the buffer size" test detects, and it is invisible
//!     from `os/readlink`, which always supplies a large enough buffer.
//!   - **`touch` converts a `double` to a time by truncation, not rounding.**
//!     `os/touch` takes integers from Janet in practice, so the fractional
//!     case has no Janet caller at all.
//!
//! ## Unix only, and deliberately
//!
//! The directory and link kernels do not exist on Windows — the public
//! functions there panic or use the CRT's own enumeration — so those sections
//! are `comptime`-guarded off rather than given a second implementation. This
//! tree's platform scope makes Windows a build target rather than a tested
//! one, and an arm written but never run is worse than an absent one.
//!
//! ## The fixture, and why it is cleaned first
//!
//! Two directories with fixed names, removed before the run as well as after.
//! A previous run that aborted mid-way leaves them behind, and then every
//! assertion fails for a reason that has nothing to do with the code. This
//! contract is kept out of `matrix.py`'s `CONTRACTS` for the reason recorded
//! there: `contracts` jobs do not take the suites lock and share one working
//! directory.

const std = @import("std");
const builtin = @import("builtin");
const abi = @import("abi");
const c = abi.c;
const harness = @import("harness.zig");

/// The runtime's own stat reader, reached by *import* rather than by symbol.
///
/// This is the first contract in the tree that needs Phase 11 Part 1's
/// arrangement for something other than a raise. `sys/stat.h` is deliberately
/// not in `abi.zig`'s translation -- `os_abi.h` records why -- so a contract
/// linking `libjanet.a` had to translate `struct stat` a second time and read
/// `st_ino`, `st_nlink` and `st_mtimespec` out of its own copy. Inside the
/// compilation there is no second copy: `host_stat.statRead` is the same
/// reader `os/stat` uses, and `Field` is the same index.
///
/// Using it to observe `janet_os_touch` and `janet_os_link` is not circular.
/// Reading metadata and writing it are different kernels; what would be
/// circular is using `statRead` to check `statRead`, which `os_stat.zig` does
/// not do either.
const host_stat = @import("subsystems").host_stat;
const Field = host_stat.Field;

const unix = builtin.os.tag != .windows;

/// The kernels, by symbol; `janet.h` declares none of them.
extern fn janet_os_dir_open(path: [*:0]const u8) callconv(.c) ?*anyopaque;
extern fn janet_os_dir_next(handle: *anyopaque, name: *?[*:0]const u8) callconv(.c) i32;
extern fn janet_os_dir_close(handle: *anyopaque) callconv(.c) void;
extern fn janet_os_link(old: [*:0]const u8, new: [*:0]const u8) callconv(.c) i32;
extern fn janet_os_symlink(old: [*:0]const u8, new: [*:0]const u8) callconv(.c) i32;
extern fn janet_os_readlink(path: [*:0]const u8, buffer: [*]u8, size: usize) callconv(.c) i64;
extern fn janet_os_touch(path: [*:0]const u8, has_times: i32, access: f64, modify: f64) callconv(.c) i32;
extern fn janet_os_realpath(path: [*:0]const u8) callconv(.c) ?[*:0]u8;

/// Borrowed from `os_fs`, which is compiled under the same condition.
extern fn janet_os_remove(path: [*:0]const u8) callconv(.c) i32;
extern fn janet_os_rmdir(path: [*:0]const u8) callconv(.c) i32;
extern fn janet_os_mkdir(path: [*:0]const u8) callconv(.c) i32;

const dir = "janet-zig-os-paths-direct-6b1d";
const file = "janet-zig-os-paths-direct-6b1d/first";
const other = "janet-zig-os-paths-direct-6b1d/second";
const sub = "janet-zig-os-paths-direct-6b1d/inner";
const hard = "janet-zig-os-paths-direct-6b1d/hard";
const soft = "janet-zig-os-paths-direct-6b1d/soft";
const missing = "janet-zig-os-paths-absent-6b1d";
const public_dir = "janet-zig-os-paths-public-4f70";

fn makeFile(path: [*:0]const u8) void {
    const handle = c.fopen(path, "wb");
    std.debug.assert(handle != null);
    std.debug.assert(c.fputs("path-contract", handle) >= 0);
    std.debug.assert(c.fclose(handle) == 0);
}

/// Best effort: every one of these may fail because the path is already gone,
/// which is the state this is reaching for.
fn cleanPaths() void {
    _ = janet_os_remove(hard);
    _ = janet_os_remove(soft);
    _ = janet_os_remove(file);
    _ = janet_os_remove(other);
    _ = janet_os_rmdir(sub);
    _ = janet_os_rmdir(dir);
    _ = janet_os_remove(public_dir ++ "/link");
    _ = janet_os_remove(public_dir ++ "/soft");
    _ = janet_os_remove(public_dir ++ "/file");
    _ = janet_os_rmdir(public_dir);
}

fn errnoValue() c_int {
    return std.c._errno().*;
}

fn setErrno(value: c_int) void {
    std.c._errno().* = value;
}

// ------------------------------------------------------------ enumeration

const Listing = struct {
    names: [16][256]u8 = undefined,
    count: usize = 0,

    fn has(self: *const Listing, name: []const u8) bool {
        for (self.names[0..self.count]) |stored| {
            if (std.mem.eql(u8, std.mem.sliceTo(&stored, 0), name)) return true;
        }
        return false;
    }
};

/// One full listing, asserting the protocol as it goes: no entry repeats, and
/// `.` and `..` never appear.
fn collect(path: [*:0]const u8) Listing {
    var listing: Listing = .{};
    const handle = janet_os_dir_open(path).?;
    defer janet_os_dir_close(handle);

    while (true) {
        var name: ?[*:0]const u8 = null;
        const status = janet_os_dir_next(handle, &name);
        std.debug.assert(status >= 0);
        if (status == 0) break;

        const entry = std.mem.span(name.?);
        std.debug.assert(!std.mem.eql(u8, entry, "."));
        std.debug.assert(!std.mem.eql(u8, entry, ".."));
        std.debug.assert(entry.len < 256);
        std.debug.assert(listing.count < 16);
        std.debug.assert(!listing.has(entry));

        @memset(&listing.names[listing.count], 0);
        @memcpy(listing.names[listing.count][0..entry.len], entry);
        listing.count += 1;
    }
    return listing;
}

fn theDirectories() void {
    std.debug.assert(janet_os_mkdir(dir) == 0);

    // An empty directory yields nothing, which is the assertion that says
    // `.` and `..` are skipped by the kernel rather than by the caller.
    std.debug.assert(collect(dir).count == 0);

    makeFile(file);
    makeFile(other);
    std.debug.assert(janet_os_mkdir(sub) == 0);

    var listing = collect(dir);
    std.debug.assert(listing.count == 3);
    std.debug.assert(listing.has("first"));
    std.debug.assert(listing.has("second"));
    std.debug.assert(listing.has("inner"));
    // Entry names, not paths.
    std.debug.assert(!listing.has(file));

    // A second pass gives the same set, so no state survives `close`.
    listing = collect(dir);
    std.debug.assert(listing.count == 3);

    // A missing directory reports through errno.
    setErrno(0);
    std.debug.assert(janet_os_dir_open(missing) == null);
    std.debug.assert(errnoValue() == @intFromEnum(std.c.E.NOENT));

    // So does a path that exists but is not a directory. Which error is the
    // host's choice, so only the failure is pinned.
    setErrno(0);
    std.debug.assert(janet_os_dir_open(file) == null);
    std.debug.assert(errnoValue() != 0);

    std.debug.assert(janet_os_rmdir(sub) == 0);
    std.debug.assert(janet_os_remove(other) == 0);
}

// ------------------------------------------------------------------ links

/// Every numeric field of one path, as `os/stat` would see them.
const Metadata = struct {
    mode: u32,
    numbers: [Field.count]f64,

    fn get(self: *const Metadata, field: Field) f64 {
        return self.numbers[@intFromEnum(field)];
    }
};

fn metadataOf(path: [*:0]const u8, follow: bool) Metadata {
    var result: Metadata = undefined;
    std.debug.assert(host_stat.statRead(path, !follow, &result.mode, &result.numbers) == 0);
    return result;
}

fn statOf(path: [*:0]const u8) Metadata {
    return metadataOf(path, true);
}

fn theLinks() void {
    // A hard link is a second name for one inode, and the link count says so.
    std.debug.assert(janet_os_link(file, hard) == 0);
    std.debug.assert(statOf(file).get(.inode) == statOf(hard).get(.inode));
    std.debug.assert(statOf(hard).get(.nlink) == 2);

    setErrno(0);
    std.debug.assert(janet_os_link(file, hard) == -1);
    std.debug.assert(errnoValue() == @intFromEnum(std.c.E.EXIST));

    setErrno(0);
    std.debug.assert(janet_os_link(missing, soft) == -1);
    std.debug.assert(errnoValue() == @intFromEnum(std.c.E.NOENT));

    std.debug.assert(janet_os_remove(hard) == 0);

    if (@hasDecl(c, "JANET_NO_SYMLINKS")) return;

    std.debug.assert(janet_os_symlink("first", soft) == 0);

    // `readlink` writes the stored target without a terminator and without
    // resolving it. The buffer is poisoned so a missing terminator is visible.
    var buffer: [256]u8 = @splat('@');
    std.debug.assert(janet_os_readlink(soft, &buffer, buffer.len) == 5);
    std.debug.assert(std.mem.eql(u8, buffer[0..5], "first"));
    std.debug.assert(buffer[5] == '@');

    // Too short a buffer truncates and reports what it wrote; see the header.
    std.debug.assert(janet_os_readlink(soft, &buffer, 3) == 3);
    std.debug.assert(std.mem.eql(u8, buffer[0..3], "fir"));

    // The link resolves for `stat` and does not for `lstat`.
    std.debug.assert(statOf(soft).get(.inode) != metadataOf(soft, false).get(.inode));

    // Reading something that is not a link fails.
    setErrno(0);
    std.debug.assert(janet_os_readlink(file, &buffer, buffer.len) == -1);
    std.debug.assert(errnoValue() == @intFromEnum(std.c.E.INVAL));

    setErrno(0);
    std.debug.assert(janet_os_symlink("first", soft) == -1);
    std.debug.assert(errnoValue() == @intFromEnum(std.c.E.EXIST));

    std.debug.assert(janet_os_remove(soft) == 0);
}

// ------------------------------------------------------------- timestamps

fn theTimestamps() void {
    std.debug.assert(janet_os_touch(file, 1, 1000000000.0, 1000000123.0) == 0);
    var info = statOf(file);
    std.debug.assert(info.get(.accessed) == 1000000000);
    std.debug.assert(info.get(.modified) == 1000000123);

    // Truncated, not rounded; see the header comment.
    std.debug.assert(janet_os_touch(file, 1, 1000000200.75, 1000000200.75) == 0);
    info = statOf(file);
    std.debug.assert(info.get(.modified) == 1000000200);

    // With no times the host supplies the current one.
    std.debug.assert(janet_os_touch(file, 0, 0, 0) == 0);
    info = statOf(file);
    std.debug.assert(info.get(.modified) > 1672531200);

    setErrno(0);
    std.debug.assert(janet_os_touch(missing, 1, 1000000000.0, 1000000000.0) == -1);
    std.debug.assert(errnoValue() == @intFromEnum(std.c.E.NOENT));
}

// --------------------------------------------------------------- realpath

fn theRealpath() void {
    if (@hasDecl(c, "JANET_NO_REALPATH")) return;

    const resolved = janet_os_realpath(dir).?;
    defer c.janet_free(@ptrCast(resolved));
    const absolute = std.mem.span(resolved);

    // Absolute, and ending in the directory's own name.
    std.debug.assert(absolute.len > dir.len);
    std.debug.assert(std.mem.endsWith(u8, absolute, dir));
    std.debug.assert(absolute[0] == '/');

    // Redundant segments are removed, so two spellings of one path agree.
    const indirect = "./" ++ dir ++ "/../" ++ dir ++ "/.";
    const again = janet_os_realpath(indirect).?;
    defer c.janet_free(@ptrCast(again));
    std.debug.assert(std.mem.eql(u8, absolute, std.mem.span(again)));

    // A missing path fails on POSIX. Windows' `_fullpath` succeeds instead and
    // the public function checks separately, which is why this is Unix-only.
    setErrno(0);
    std.debug.assert(janet_os_realpath(missing) == null);
    std.debug.assert(errnoValue() == @intFromEnum(std.c.E.NOENT));
}

// -------------------------------------------------------- the Janet surface

var environment: [*c]c.JanetTable = undefined;

fn eval(source: [*:0]const u8) void {
    var result: c.Janet = undefined;
    std.debug.assert(c.janet_dostring(environment, source, "os-fs-paths-contract", &result) == 0);
}

fn theCoreFunctions() void {
    eval(
        \\(os/mkdir "janet-zig-os-paths-public-4f70")
        \\(spit "janet-zig-os-paths-public-4f70/file" "path-contract")
    );

    // `os/dir` answers entry names, and *appends* to a supplied array rather
    // than replacing its contents -- which is why the length is two.
    eval(
        \\(def entries (os/dir "janet-zig-os-paths-public-4f70"))
        \\(assert (array? entries))
        \\(assert (= 1 (length entries)))
        \\(assert (= "file" (first entries)))
        \\(def supplied @[:kept])
        \\(def same (os/dir "janet-zig-os-paths-public-4f70" supplied))
        \\(assert (= same supplied))
        \\(assert (= 2 (length supplied)))
        \\(assert (= :kept (first supplied)))
    );

    if (!@hasDecl(c, "JANET_NO_SYMLINKS")) {
        // `os/link` is hard by default and symbolic when asked; `os/symlink`
        // is the same as passing true.
        eval(
            \\(os/link "janet-zig-os-paths-public-4f70/file" "janet-zig-os-paths-public-4f70/link")
            \\(assert (= 2 ((os/stat "janet-zig-os-paths-public-4f70/link") :nlink)))
            \\(os/symlink "file" "janet-zig-os-paths-public-4f70/soft")
            \\(assert (= :link ((os/lstat "janet-zig-os-paths-public-4f70/soft") :mode)))
            \\(assert (= :file ((os/stat "janet-zig-os-paths-public-4f70/soft") :mode)))
            \\(assert (= "file" (os/readlink "janet-zig-os-paths-public-4f70/soft")))
            \\(os/rm "janet-zig-os-paths-public-4f70/soft")
            \\(os/rm "janet-zig-os-paths-public-4f70/link")
        );
    }

    // `os/touch` sets both times, defaults the modification time to the access
    // time, and defaults both to now.
    eval(
        \\(os/touch "janet-zig-os-paths-public-4f70/file" 1000000000 1000000123)
        \\(def stats (os/stat "janet-zig-os-paths-public-4f70/file"))
        \\(assert (= 1000000000 (stats :accessed)))
        \\(assert (= 1000000123 (stats :modified)))
        \\(os/touch "janet-zig-os-paths-public-4f70/file" 1000000200)
        \\(def stats (os/stat "janet-zig-os-paths-public-4f70/file"))
        \\(assert (= 1000000200 (stats :accessed)))
        \\(assert (= 1000000200 (stats :modified)))
        \\(os/touch "janet-zig-os-paths-public-4f70/file")
        \\(assert (> ((os/stat "janet-zig-os-paths-public-4f70/file") :modified) 1672531200))
    );

    if (!@hasDecl(c, "JANET_NO_REALPATH")) {
        eval(
            \\(assert (= (os/realpath ".") (os/cwd)))
            \\(def resolved (os/realpath "janet-zig-os-paths-public-4f70"))
            \\(assert (string? resolved))
            \\(assert (= resolved (os/realpath "./janet-zig-os-paths-public-4f70/.")))
        );
    }
}

/// The refusals, which the C contract could only reach through `protect`
/// inside a Janet string.
fn theRefusals() void {
    var args: [2]c.Janet = undefined;
    args[0] = c.janet_cstringv(missing);

    std.debug.assert(harness.raised(harness.core("os/dir"), .{ @as(i32, 1), &args }) != null);
    std.debug.assert(harness.raised(harness.core("os/touch"), .{ @as(i32, 1), &args }) != null);

    if (!@hasDecl(c, "JANET_NO_REALPATH")) {
        std.debug.assert(harness.raised(harness.core("os/realpath"), .{ @as(i32, 1), &args }) != null);
    }

    if (!@hasDecl(c, "JANET_NO_SYMLINKS")) {
        // Reading a link that is not one, and linking onto a name that exists.
        args[0] = c.janet_cstringv(public_dir ++ "/file");
        std.debug.assert(harness.raised(harness.core("os/readlink"), .{ @as(i32, 1), &args }) != null);
        args[1] = args[0];
        std.debug.assert(harness.raised(harness.core("os/link"), .{ @as(i32, 2), &args }) != null);
    }
}

fn tearDown() void {
    eval(
        \\(os/rm "janet-zig-os-paths-public-4f70/file")
        \\(os/rmdir "janet-zig-os-paths-public-4f70")
    );
}

pub fn run() void {
    cleanPaths();

    if (unix) {
        theDirectories();
        theLinks();
    } else {
        std.debug.assert(janet_os_mkdir(dir) == 0);
        makeFile(file);
    }
    theTimestamps();
    if (unix) theRealpath();

    _ = c.janet_init();
    environment = c.janet_core_env(null);
    theCoreFunctions();
    theRefusals();
    tearDown();
    c.janet_deinit();

    cleanPaths();
}
