//! Behavioral contract for directory enumeration, links, timestamps and
//! canonical paths: the kernels behind `os/dir`, `os/link`, `os/symlink`,
//! `os/readlink`, `os/touch` and `os/realpath`.
//!
//! ## What only the kernels can be asked
//!
//! Each of these has a shape at the C level that the Janet function smooths
//! over, and the smoothing is where a port goes wrong:
//!
//!   - enumeration is a three-call protocol, open then next until it returns
//!     zero then close, and `next` must skip `.` and `..` itself. `os/dir`
//!     returns a finished array, so nothing above it can tell a skipped entry
//!     from one that was never produced.
//!   - `readlink` truncates rather than failing when the buffer is too short,
//!     and gives back the length written. That is what the caller's "length
//!     reached the buffer size" test detects, and it is invisible from
//!     `os/readlink`, which always supplies a large enough buffer.
//!   - `touch` converts a `double` to a time by truncation rather than
//!     rounding. `os/touch` takes integers from Janet in practice, so the
//!     fractional case has no Janet caller at all.
//!
//! ## Unix only, and deliberately
//!
//! The directory and link kernels do not exist on Windows, the public
//! functions there panicking or using the CRT's own enumeration, so those
//! sections
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

// ==========================================================================
// Standard library imports
// ==========================================================================

const std = @import("std");
const builtin = @import("builtin");

// ==========================================================================
// Project imports
// ==========================================================================

const c = @import("cabi");
const config = @import("config");
const core_env = @import("subsystems").env;
const expect = @import("expect.zig").expect;
const fs = @import("subsystems").fs;
const harness = @import("harness.zig");

/// The runtime's own stat reader, reached by *import* rather than by symbol.
///
/// This is the first contract in the tree that needs to be inside the
/// compilation for something other than a raise. `sys/stat.h` is deliberately
/// outside the host translations, for which `os/abi.h` records the reason, so
/// a contract
/// linking `libwattle.a` would have to translate `struct stat` a second time
/// and read `st_ino`, `st_nlink` and `st_mtimespec` out of its own copy.
/// Inside the
/// compilation there is no second copy: `host_stat.statRead` is the same
/// reader `os/stat` uses, and `Field` is the same index.
///
/// Using it to observe `fs.touch` and `fs.hardLink` is not circular.
/// Reading metadata and writing it are different kernels; what would be
/// circular is using `statRead` to check `statRead`, and nothing here does.
const host_stat = @import("subsystems").host_stat;
const repr = @import("repr");
const tables = @import("subsystems").value.tables;
const utils = @import("subsystems").utils;
const value = @import("subsystems").value;
const vm_lifecycle = @import("subsystems").lifecycle;

// ==========================================================================
// Constants
// ==========================================================================

const dir = "wattle-os-paths-direct-6b1d";
var environment: *tables.Table = undefined;
const file = "wattle-os-paths-direct-6b1d/first";
const hard = "wattle-os-paths-direct-6b1d/hard";
const missing = "wattle-os-paths-absent-6b1d";
const other = "wattle-os-paths-direct-6b1d/second";
const public_dir = "wattle-os-paths-public-4f70";
const soft = "wattle-os-paths-direct-6b1d/soft";
const sub = "wattle-os-paths-direct-6b1d/inner";
const unix = builtin.os.tag != .windows;

// ==========================================================================
// Aliased types
// ==========================================================================

const Field = host_stat.Field;

// ==========================================================================
// Types
// ==========================================================================

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

/// Every numeric field of one path, as `os/stat` would see them.
const Metadata = struct {
    mode: u32,
    numbers: [Field.count]f64,

    fn get(self: *const Metadata, field: Field) f64 {
        return self.numbers[@intFromEnum(field)];
    }
};

// ==========================================================================
// Cases
// ==========================================================================

fn makeFile(path: [*:0]const u8) void {
    const handle = c.fopen(path, "wb");
    expect(handle != null);
    expect(c.fputs("path-contract", handle) >= 0);
    expect(c.fclose(handle) == 0);
}

/// Best effort: every one of these may fail because the path is already gone,
/// which is the state this is reaching for.
fn cleanPaths() void {
    _ = fs.hostRemove(hard);
    _ = fs.hostRemove(soft);
    _ = fs.hostRemove(file);
    _ = fs.hostRemove(other);
    _ = fs.hostRmdir(sub);
    _ = fs.hostRmdir(dir);
    _ = fs.hostRemove(public_dir ++ "/empty");
    _ = fs.hostRemove(public_dir ++ "/link");
    _ = fs.hostRemove(public_dir ++ "/soft");
    _ = fs.hostRemove(public_dir ++ "/file");
    _ = fs.hostRmdir(public_dir);
}

fn errnoValue() c_int {
    return std.c._errno().*;
}

fn setErrno(code: c_int) void {
    std.c._errno().* = code;
}

fn eval(source: [*:0]const u8) void {
    var result: repr.Value = undefined;
    expect(core_env.dostring(environment, source, "os-fs-paths-contract", &result) == 0);
}

/// One full listing, asserting the protocol as it goes: no entry repeats, and
/// `.` and `..` never appear.
fn collect(path: [*:0]const u8) Listing {
    var listing: Listing = .{};
    const handle = fs.dirOpen(path).?;
    defer fs.dirClose(handle);

    while (true) {
        var name: [*:0]const u8 = undefined;
        const status = fs.dirNextAbi(handle, &name);
        expect(status >= 0);
        if (status == 0) break;

        const entry = std.mem.span(name);
        expect(!std.mem.eql(u8, entry, "."));
        expect(!std.mem.eql(u8, entry, ".."));
        expect(entry.len < 256);
        expect(listing.count < 16);
        expect(!listing.has(entry));

        @memset(&listing.names[listing.count], 0);
        @memcpy(listing.names[listing.count][0..entry.len], entry);
        listing.count += 1;
    }
    return listing;
}

fn theDirectories() void {
    expect(fs.hostMkdir(dir) == 0);

    // An empty directory yields nothing, which is the assertion that says
    // `.` and `..` are skipped by the kernel rather than by the caller.
    expect(collect(dir).count == 0);

    makeFile(file);
    makeFile(other);
    expect(fs.hostMkdir(sub) == 0);

    var listing = collect(dir);
    expect(listing.count == 3);
    expect(listing.has("first"));
    expect(listing.has("second"));
    expect(listing.has("inner"));
    // Entry names, not paths.
    expect(!listing.has(file));

    // A second pass gives the same set, so no state survives `close`.
    listing = collect(dir);
    expect(listing.count == 3);

    // A missing directory reports through errno.
    setErrno(0);
    expect(fs.dirOpen(missing) == null);
    expect(errnoValue() == @intFromEnum(std.c.E.NOENT));

    // So does a path that exists but is not a directory. Which error is the
    // host's choice, so only the failure is pinned.
    setErrno(0);
    expect(fs.dirOpen(file) == null);
    expect(errnoValue() != 0);

    expect(fs.hostRmdir(sub) == 0);
    expect(fs.hostRemove(other) == 0);
}

fn metadataOf(path: [*:0]const u8, follow: bool) Metadata {
    var result: Metadata = undefined;
    expect(host_stat.statRead(path, !follow, &result.mode, &result.numbers) == 0);
    return result;
}

fn statOf(path: [*:0]const u8) Metadata {
    return metadataOf(path, true);
}

fn theLinks() void {
    // A hard link is a second name for one inode, and the link count says so.
    expect(fs.hardLink(file, hard) == 0);
    expect(statOf(file).get(.inode) == statOf(hard).get(.inode));
    expect(statOf(hard).get(.nlink) == 2);

    setErrno(0);
    expect(fs.hardLink(file, hard) == -1);
    expect(errnoValue() == @intFromEnum(std.c.E.EXIST));

    setErrno(0);
    expect(fs.hardLink(missing, soft) == -1);
    expect(errnoValue() == @intFromEnum(std.c.E.NOENT));

    expect(fs.hostRemove(hard) == 0);

    if (!config.symlinks) return;

    expect(fs.symbolicLink("first", soft) == 0);

    // `readlink` writes the stored target without a terminator and without
    // resolving it. The buffer is poisoned so a missing terminator is visible.
    var buffer: [256]u8 = @splat('@');
    expect(fs.readLink(soft, &buffer, buffer.len) == 5);
    expect(std.mem.eql(u8, buffer[0..5], "first"));
    expect(buffer[5] == '@');

    // Too short a buffer truncates and reports what it wrote; see the header.
    expect(fs.readLink(soft, &buffer, 3) == 3);
    expect(std.mem.eql(u8, buffer[0..3], "fir"));

    // The link resolves for `stat` and does not for `lstat`.
    expect(statOf(soft).get(.inode) != metadataOf(soft, false).get(.inode));

    // Reading something that is not a link fails.
    setErrno(0);
    expect(fs.readLink(file, &buffer, buffer.len) == -1);
    expect(errnoValue() == @intFromEnum(std.c.E.INVAL));

    setErrno(0);
    expect(fs.symbolicLink("first", soft) == -1);
    expect(errnoValue() == @intFromEnum(std.c.E.EXIST));

    expect(fs.hostRemove(soft) == 0);
}

fn theTimestamps() void {
    expect(fs.touch(file, true, 1000000000.0, 1000000123.0) == 0);
    var info = statOf(file);
    expect(info.get(.accessed) == 1000000000);
    expect(info.get(.modified) == 1000000123);

    // Truncated, not rounded; see the header comment.
    expect(fs.touch(file, true, 1000000200.75, 1000000200.75) == 0);
    info = statOf(file);
    expect(info.get(.modified) == 1000000200);

    // A time no `time_t` holds saturates rather than trapping. 2^63 is the
    // edge: `maxInt(i64)` rounds to it as a double, and it is one more than an
    // `i64` holds. What the host then does with the saturated value is the
    // host's: a POSIX filesystem stores it, and WASI, whose timestamps are
    // unsigned nanoseconds in 64 bits, has no room for that many seconds and
    // refuses it. The saturation is what this asserts either way -- the call
    // returns rather than trapping on the conversion.
    const saturated = fs.touch(file, true, 0x1p63, 0x1p63);
    expect(if (builtin.os.tag == .wasi) saturated == -1 else saturated == 0);

    // With no times the host supplies the current one.
    expect(fs.touch(file, false, 0, 0) == 0);
    info = statOf(file);
    expect(info.get(.modified) > 1672531200);

    setErrno(0);
    expect(fs.touch(missing, true, 1000000000.0, 1000000000.0) == -1);
    expect(errnoValue() == @intFromEnum(std.c.E.NOENT));
}

fn theRealpath() void {
    if (!config.realpath) return;

    const resolved = fs.canonicalPath(dir).?;
    defer utils.free(@ptrCast(resolved));
    const absolute = std.mem.span(resolved);

    // Absolute, and ending in the directory's own name.
    expect(absolute.len > dir.len);
    expect(std.mem.endsWith(u8, absolute, dir));
    expect(absolute[0] == '/');

    // Redundant segments are removed, so two spellings of one path agree.
    const indirect = "./" ++ dir ++ "/../" ++ dir ++ "/.";
    const again = fs.canonicalPath(indirect).?;
    defer utils.free(@ptrCast(again));
    expect(std.mem.eql(u8, absolute, std.mem.span(again)));

    // A missing path fails on POSIX. Windows' `_fullpath` succeeds instead and
    // the public function checks separately, so this stays Unix-only.
    setErrno(0);
    expect(fs.canonicalPath(missing) == null);
    expect(errnoValue() == @intFromEnum(std.c.E.NOENT));
}

fn theCoreFunctions() void {
    eval(
        \\(os/mkdir "wattle-os-paths-public-4f70")
        \\(spit "wattle-os-paths-public-4f70/file" "path-contract")
    );

    // `os/dir` gives entry names, and *appends* to a supplied array rather
    // than replacing its contents, so the length is two.
    eval(
        \\(def entries (os/dir "wattle-os-paths-public-4f70"))
        \\(assert (array? entries))
        \\(assert (= 1 (length entries)))
        \\(assert (= "file" (first entries)))
        \\(def supplied @[:kept])
        \\(def same (os/dir "wattle-os-paths-public-4f70" supplied))
        \\(assert (= same supplied))
        \\(assert (= 2 (length supplied)))
        \\(assert (= :kept (first supplied)))
    );

    if (config.symlinks) {
        // `os/link` is hard by default and symbolic when asked; `os/symlink`
        // is the same as passing true.
        eval(
            \\(os/link "wattle-os-paths-public-4f70/file" "wattle-os-paths-public-4f70/link")
            \\(assert (= 2 ((os/stat "wattle-os-paths-public-4f70/link") :nlink)))
            \\(os/symlink "file" "wattle-os-paths-public-4f70/soft")
            \\(assert (= :link ((os/lstat "wattle-os-paths-public-4f70/soft") :mode)))
            \\(assert (= :file ((os/stat "wattle-os-paths-public-4f70/soft") :mode)))
            \\(assert (= "file" (os/readlink "wattle-os-paths-public-4f70/soft")))
            \\(os/rm "wattle-os-paths-public-4f70/soft")
            \\(os/rm "wattle-os-paths-public-4f70/link")
        );

        // macOS stores an empty target, where Linux refuses one, and it reads
        // back as the empty string: a length of zero is not a failure.
        if (builtin.os.tag == .macos) eval(
            \\(os/symlink "" "wattle-os-paths-public-4f70/empty")
            \\(assert (= "" (os/readlink "wattle-os-paths-public-4f70/empty")))
            \\(os/rm "wattle-os-paths-public-4f70/empty")
        );
    }

    // `os/touch` sets both times, defaults the modification time to the access
    // time, and defaults both to now.
    eval(
        \\(os/touch "wattle-os-paths-public-4f70/file" 1000000000 1000000123)
        \\(def stats (os/stat "wattle-os-paths-public-4f70/file"))
        \\(assert (= 1000000000 (stats :accessed)))
        \\(assert (= 1000000123 (stats :modified)))
        \\(os/touch "wattle-os-paths-public-4f70/file" 1000000200)
        \\(def stats (os/stat "wattle-os-paths-public-4f70/file"))
        \\(assert (= 1000000200 (stats :accessed)))
        \\(assert (= 1000000200 (stats :modified)))
        \\(os/touch "wattle-os-paths-public-4f70/file")
        \\(assert (> ((os/stat "wattle-os-paths-public-4f70/file") :modified) 1672531200))
    );

    // A time outside `time_t` is refused, at either bound and in either
    // argument. 2^63 and its negation are the bounds as doubles.
    eval(
        \\(defn refused [& args] (in (protect (os/touch ;args)) 1))
        \\(def f "wattle-os-paths-public-4f70/file")
        \\(def edge (math/pow 2 63))
        \\(assert (= "invalid argument to touch" (refused f edge)))
        \\(assert (= "invalid argument to touch" (refused f (- edge))))
        \\(assert (= "invalid argument to touch" (refused f 1000 edge)))
        \\(assert (= "invalid argument to touch" (refused f edge 1000)))
    );

    if (config.realpath) {
        eval(
            \\(assert (= (os/realpath ".") (os/cwd)))
            \\(def resolved (os/realpath "wattle-os-paths-public-4f70"))
            \\(assert (string? resolved))
            \\(assert (= resolved (os/realpath "./wattle-os-paths-public-4f70/.")))
        );
    }
}

/// The refusals, each reached by calling the cfunction directly so that the
/// message is a value rather than something printed inside a Janet string.
fn theRefusals() void {
    var args: [2]repr.Value = undefined;
    args[0] = value.fromBytes(missing, .string);

    expect(harness.raised(harness.core("os/dir"), .{args[0..1]}) != null);
    expect(harness.raised(harness.core("os/touch"), .{args[0..1]}) != null);

    if (config.realpath) {
        expect(harness.raised(harness.core("os/realpath"), .{args[0..1]}) != null);
    }

    if (config.symlinks) {
        // Reading a link that is not one, and linking onto a name that exists.
        args[0] = value.fromBytes(public_dir ++ "/file", .string);
        expect(harness.raised(harness.core("os/readlink"), .{args[0..1]}) != null);
        args[1] = args[0];
        expect(harness.raised(harness.core("os/link"), .{args[0..2]}) != null);
    }
}

fn tearDown() void {
    eval(
        \\(os/rm "wattle-os-paths-public-4f70/file")
        \\(os/rmdir "wattle-os-paths-public-4f70")
    );
}

// ==========================================================================
// Entry
// ==========================================================================

pub fn run() void {
    cleanPaths();

    if (unix) {
        theDirectories();
        theLinks();
    } else {
        expect(fs.hostMkdir(dir) == 0);
        makeFile(file);
    }
    theTimestamps();
    if (unix) theRealpath();

    harness.init();
    environment = harness.coreEnv();
    theCoreFunctions();
    theRefusals();
    tearDown();
    vm_lifecycle.deinit();

    cleanPaths();
}
