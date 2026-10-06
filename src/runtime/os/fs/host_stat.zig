//! `stat`, `lstat` and `fstat`, and the structure each fills, per platform.
//!
//! `os/stat` reports fifteen fields, and no one declaration of `struct stat`
//! serves every platform the runtime builds for:
//!
//! | platform | route |
//! | --- | --- |
//! | macOS, FreeBSD, WASI | `std.c.Stat` |
//! | Linux | `statx`, whose structure `std.os.linux.Statx` declares |
//! | mingw | `struct _stat64` and `_stat64`, declared here |
//!
//! `std.c.Stat` is `void` on Linux, and `std.os.linux` declares no `Stat` and
//! no `fstatat`, so the Linux arm calls `statx`. `std.Io.File.Stat` has nine
//! fields where `os/stat` reports fifteen. `std.c` declares no `lstat`, so the
//! three calls are declared here by symbol for every platform but mingw.
//!
//! One field is reconstructed rather than copied: `statx` reports the device as
//! a major and a minor rather than as a `dev_t`, so `dev` and `rdev` are
//! recombined by `encodeDev` below, which says how and what checks it.

// ==========================================================================
// Standard library imports
// ==========================================================================

const std = @import("std");
const builtin = @import("builtin");

// ==========================================================================
// Project imports
// ==========================================================================

const c = @import("cabi");

// ==========================================================================
// Constants
// ==========================================================================

/// The file-type mask and the directory type, which is all of `<sys/stat.h>`'s
/// mode macros this file needs.
const S_IFDIR: u32 = 0o040000;
const S_IFMT: u32 = 0o170000;

/// `fstat`, `lstat` and `stat`, declared by symbol because `std.c` declares no
/// `lstat`. Each takes this file's `Stat`.
const c_fstat: *const fn (c_int, *Stat) callconv(.c) c_int =
    @extern(*const fn (c_int, *Stat) callconv(.c) c_int, .{ .name = fstat_name });

const c_lstat: *const fn ([*:0]const u8, *Stat) callconv(.c) c_int =
    @extern(*const fn ([*:0]const u8, *Stat) callconv(.c) c_int, .{ .name = lstat_name });

const c_stat: *const fn ([*:0]const u8, *Stat) callconv(.c) c_int =
    @extern(*const fn ([*:0]const u8, *Stat) callconv(.c) c_int, .{ .name = stat_name });

/// mingw's `_stat64`, the CRT's call that fills `struct _stat64`.
extern "c" fn _stat64(path: [*:0]const u8, buf: *WinStat64) c_int;

/// Whether this target is the Darwin architecture whose plain `stat` symbol is
/// the pre-widening structure.
///
/// On x86-64 Darwin the plain names stayed bound to the 32-bit `ino_t`
/// structure and the wide one is `$INODE64`; arm64 has no such history, so
/// there the plain names are the wide structure. That is the same table
/// `std.c` has.
const darwin_inode64 = switch (builtin.target.os.tag) {
    .macos, .ios, .tvos, .watchos, .visionos, .driverkit => builtin.target.cpu.arch == .x86_64,
    else => false,
};

/// The three symbol names, which is where `darwin_inode64` is spent. mingw
/// takes `_stat64` instead and names none of them.
const fstat_name = if (darwin_inode64) "fstat$INODE64" else "fstat";

const lstat_name = if (darwin_inode64) "lstat$INODE64" else "lstat";

const stat_name = if (darwin_inode64) "stat$INODE64" else "stat";

/// Whether this target takes the `statx` arm, and whether it takes the arm
/// with no `lstat` at all.
const linux = builtin.target.os.tag == .linux;
const windows = builtin.target.os.tag == .windows;
const freebsd = builtin.target.os.tag == .freebsd;

// ==========================================================================
// Aliased types
// ==========================================================================

/// The structure the stat calls fill: mingw's `struct _stat64`, and
/// `std.c.Stat` elsewhere. The Linux arm never names it.
const Stat = if (windows) WinStat64 else std.c.Stat;

// ==========================================================================
// Types
// ==========================================================================

/// The fields `os/stat` reports, in the order the numbers array has them.
/// `os/fs/stat.zig` has the keyword table that indexes it.
pub const Field = enum(usize) {
    dev = 0,
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

    pub const count = @typeInfo(Field).@"enum".field_names.len;
};

/// mingw's `struct _stat64`, which `_stat64` fills: 64-bit size and times, a
/// sixteen-bit `st_ino`, and no `st_blocks` or `st_blksize`.
///
/// It is `_stat64` and not `stat` because mingw picks the layout and the
/// symbol together. Under `_FILE_OFFSET_BITS=64` its `stat` is an assembler
/// label onto `stat64`, and the plain `stat` symbol fills the 48-byte
/// `_stat64i32`, whose `st_size` is at the offset of `_stat64`'s access time.
const WinStat64 = extern struct {
    st_dev: c_uint,
    st_ino: c_ushort,
    st_mode: c_ushort,
    st_nlink: c_short,
    st_uid: c_short,
    st_gid: c_short,
    st_rdev: c_uint,
    st_size: c_longlong,
    st_atime: c_longlong,
    st_mtime: c_longlong,
    st_ctime: c_longlong,
};

// ==========================================================================
// Public functions
// ==========================================================================

/// Whether an open stream is a directory, which `file/open` has to reject.
///
/// It is here rather than in `io.zig` for the reason the whole file exists: it
/// needs `struct stat`, and naming one is the thing that is per-platform.
///
/// The call's result is checked and the buffer is zeroed before it. Reading
/// the mode word regardless would leave the result to whatever was on the
/// stack when the call fails; zeroing alone would make it determinate, and
/// coming back `false` is what says the question could not be asked. Both arms
/// do the same thing.
pub fn isDirectory(file: ?*anyopaque) bool {
    if (windows or builtin.target.os.tag == .plan9) return false;
    return descriptorIsDirectory(c.fileno(file)) orelse false;
}

/// Whether an open descriptor is a directory, or null where the call failed.
/// `isDirectory` asks it of a stream's descriptor. Windows and Plan 9 do not
/// call it.
pub fn descriptorIsDirectory(fd: c_int) ?bool {
    if (linux) {
        const l = std.os.linux;
        var stx: l.Statx = std.mem.zeroes(l.Statx);
        const rc = l.statx(fd, "", l.AT.EMPTY_PATH, l.STATX.BASIC_STATS, &stx);
        if (@as(isize, @bitCast(rc)) < 0) return null;
        return (stx.mode & S_IFMT) == S_IFDIR;
    }
    var st: Stat = std.mem.zeroes(Stat);
    if (c_fstat(fd, &st) < 0) return null;
    return (@as(u32, @intCast(st.mode)) & S_IFMT) == S_IFDIR;
}

/// Stats a path and copies out the mode word and one double per numeric field.
/// Every Janet value `os/stat` produces is built from this.
pub fn statRead(path: [*:0]const u8, do_lstat: bool, mode: *u32, numbers: [*]f64) i32 {
    return if (linux)
        readStatx(path, do_lstat, mode, numbers)
    else if (windows)
        readWinStat(path, mode, numbers)
    else
        readStdStat(path, do_lstat, mode, numbers);
}

// ==========================================================================
// Private functions
// ==========================================================================

/// The kernel's `new_encode_dev` encoding: twenty bits of major above
/// thirty-two, twelve more at bit eight, and the minor split either side of
/// it. glibc's `makedev` and musl's produce the same bits; this is not a
/// choice between conventions, it is the one encoding.
///
/// `test/os_stat.zig` checks it by the property a Janet program relies on
/// rather than by pinning the number: two files on the same filesystem report
/// the same `dev`, and a file agrees with its directory. A wrong encoding
/// fails that; a different but consistent one does not, and is not something
/// this runtime should be asserting.
fn encodeDev(major: u32, minor: u32) u64 {
    return (@as(u64, major & 0xfffff000) << 32) |
        (@as(u64, major & 0x00000fff) << 8) |
        (@as(u64, minor & 0xffffff00) << 12) |
        @as(u64, minor & 0x000000ff);
}

/// Writes one field of the numbers array by name.
inline fn put(numbers: [*]f64, field: Field, value: f64) void {
    numbers[@backingInt(field)] = value;
}

/// The mingw arm, over `struct _stat64`. Windows has no `lstat`, so a
/// symlink is followed whatever the caller asked for.
fn readWinStat(path: [*:0]const u8, mode: *u32, numbers: [*]f64) i32 {
    var st: WinStat64 = undefined;
    if (_stat64(path, &st) == -1) return -1;

    zeroAll(numbers);
    mode.* = st.st_mode;
    put(numbers, .dev, @floatFromInt(st.st_dev));
    // Windows writes a zero here. Its `_ino_t` is sixteen bits and its
    // filesystems do not fill the field, so the identity a POSIX caller reads
    // from `inode` is not one this platform reports; the zero is copied
    // rather than invented, and `test/os_surface.zig` pins it.
    put(numbers, .inode, @floatFromInt(st.st_ino));
    put(numbers, .uid, @floatFromInt(st.st_uid));
    put(numbers, .gid, @floatFromInt(st.st_gid));
    put(numbers, .nlink, @floatFromInt(st.st_nlink));
    put(numbers, .rdev, @floatFromInt(st.st_rdev));
    put(numbers, .size, @floatFromInt(st.st_size));
    put(numbers, .accessed, @floatFromInt(st.st_atime));
    put(numbers, .modified, @floatFromInt(st.st_mtime));
    put(numbers, .changed, @floatFromInt(st.st_ctime));
    // `blocks` and `blocksize` are never written on Windows, and that is what
    // the zeroing above is for: a descriptor's unwritten fields are part of
    // what a caller reads, and nothing about the type says so.
    return 0;
}

/// The macOS, FreeBSD and WASI arm, over `std.c.Stat`. Darwin names the times
/// `atimespec` and the others `atim`, and `atime` returns either.
fn readStdStat(path: [*:0]const u8, do_lstat: bool, mode: *u32, numbers: [*]f64) i32 {
    var st: Stat = undefined;
    const res = if (do_lstat) c_lstat(path, &st) else c_stat(path, &st);
    if (res == -1) return -1;

    zeroAll(numbers);
    mode.* = @intCast(st.mode);
    put(numbers, .dev, @floatFromInt(st.dev));
    put(numbers, .inode, @floatFromInt(st.ino));
    put(numbers, .uid, @floatFromInt(st.uid));
    put(numbers, .gid, @floatFromInt(st.gid));
    put(numbers, .nlink, @floatFromInt(st.nlink));
    put(numbers, .rdev, @floatFromInt(st.rdev));
    put(numbers, .size, @floatFromInt(st.size));
    put(numbers, .accessed, @floatFromInt(st.atime().sec));
    put(numbers, .modified, @floatFromInt(st.mtime().sec));
    put(numbers, .changed, @floatFromInt(st.ctime().sec));
    put(numbers, .blocks, @floatFromInt(st.blocks));
    put(numbers, .blocksize, @floatFromInt(st.blksize));
    return 0;
}

/// The Linux arm, over `statx`.
fn readStatx(path: [*:0]const u8, do_lstat: bool, mode: *u32, numbers: [*]f64) i32 {
    const l = std.os.linux;
    var stx: l.Statx = undefined;
    const flags: u32 = if (do_lstat) l.AT.SYMLINK_NOFOLLOW else 0;
    const rc = l.statx(l.AT.FDCWD, path, flags, l.STATX.BASIC_STATS, &stx);
    if (@as(isize, @bitCast(rc)) < 0) return -1;

    zeroAll(numbers);
    mode.* = stx.mode;
    put(numbers, .dev, @floatFromInt(encodeDev(stx.dev_major, stx.dev_minor)));
    put(numbers, .inode, @floatFromInt(stx.ino));
    put(numbers, .uid, @floatFromInt(stx.uid));
    put(numbers, .gid, @floatFromInt(stx.gid));
    put(numbers, .nlink, @floatFromInt(stx.nlink));
    put(numbers, .rdev, @floatFromInt(encodeDev(stx.rdev_major, stx.rdev_minor)));
    put(numbers, .size, @floatFromInt(stx.size));
    put(numbers, .accessed, @floatFromInt(stx.atime.sec));
    put(numbers, .modified, @floatFromInt(stx.mtime.sec));
    put(numbers, .changed, @floatFromInt(stx.ctime.sec));
    put(numbers, .blocks, @floatFromInt(stx.blocks));
    put(numbers, .blocksize, @floatFromInt(stx.blksize));
    return 0;
}

/// Zeroes every slot. Called after the syscall succeeds and never before,
/// which is Janet's order and is what `test/os_surface.zig` asserts: a path
/// that cannot be stat'ed leaves both `mode` and `numbers` untouched. Zeroing
/// first is the obvious way to write this and is wrong.
///
/// After success it is required: two slots are never written on Windows and
/// the Linux arm writes a different set again, and a descriptor's unwritten
/// fields are part of what a caller reads with nothing about the type to say
/// so.
inline fn zeroAll(numbers: [*]f64) void {
    for (0..Field.count) |i| numbers[i] = 0;
}

// ==========================================================================
// Tests
// ==========================================================================

// `std.c.Stat` is the size of FreeBSD 12's `struct stat`, 224 bytes, and
// x86-64 mingw's `struct _stat64` is 56 bytes with the size at offset 24.
comptime {
    if (freebsd) std.debug.assert(@sizeOf(Stat) == 224);
    if (windows and builtin.target.cpu.arch == .x86_64) {
        std.debug.assert(@sizeOf(WinStat64) == 56);
        std.debug.assert(@offsetOf(WinStat64, "st_size") == 24);
    }
}
