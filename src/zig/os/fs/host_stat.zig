//! `stat`, `lstat` and `fstat`, and the one place in this port where
//! `@cImport` is not the answer.
//!
//! ## Why this file exists
//!
//! Host structures stay libc's, reached with `@cImport`. `struct stat` is the
//! single measured exception: **musl declares `struct timespec` with a
//! bitfield** -- zero-width padding, written as
//! `int :8*(sizeof(time_t)-sizeof(long))*(__BYTE_ORDER==4321)` -- and
//! `translate-c` demotes any record holding a bitfield to `opaque {}`.
//! `struct stat` embeds three timespecs, so it is demoted in turn and Zig can
//! neither size it nor place one on the stack. macOS and mingw both translate
//! it completely, which is exactly what makes it easy to miss.
//!
//! ## What replaces it, per platform
//!
//! | platform | route |
//! | --- | --- |
//! | macOS, mingw | `@cImport`'s `struct stat`, which translates completely |
//! | Linux | `statx`, whose structure Zig defines itself |
//!
//! Zig's own standard library was checked first and does not supply one:
//! `std.posix.Stat` is `void` on Linux and Windows, `std.posix.fstat` and
//! `fstatat` do not exist in 0.16, `std.os.linux.Stat` was removed, and
//! `std.Io.File.Stat` carries nine fields where `os/stat` reports fifteen --
//! it has no `dev`, `uid`, `gid`, `rdev` or `blocks`, and `std.Io` has setters
//! for owner but no getter anywhere. What Zig *does* supply on Linux is
//! `std.os.linux.Statx`, which has every field `os/stat` needs.
//!
//! ## The one field that is reconstructed, and how it is checked
//!
//! `statx` reports the device as a major and a minor rather than as a `dev_t`,
//! so `dev` and `rdev` are recombined here with the kernel's own
//! `new_encode_dev` encoding -- the same one glibc's `makedev` and musl's
//! produce, because all three are describing the same kernel field.
//!
//! That is the only value in this file that is computed rather than copied,
//! and `test/os_stat.zig` checks it by the property a Janet program actually
//! relies on rather than by pinning the number: **two files on the same
//! filesystem report the same `dev`, and a file agrees with its directory.**
//! A wrong encoding fails that; a different-but-consistent one does not, and
//! is not something this runtime should be asserting.

const std = @import("std");
const builtin = @import("builtin");
const c = @import("cabi");

const linux = builtin.os.tag == .linux;
const windows = builtin.os.tag == .windows;

/// A translation of `<sys/stat.h>` alone, and one of seven in the tree beside
/// `os/abi.h`, `net/abi.h`, `filewatch/abi.h`, `ev/locks.zig`, `host.zig` and
/// `cabi.zig`. A translation is right when nothing it declares crosses a
/// subsystem boundary, and nothing does: `struct stat` never leaves this file,
/// and what does leave is a mode word and an array of doubles.
///
/// It is translated on every target, including the musl ones where the result
/// is `opaque {}`. That is harmless because the Linux arm never names it, and a
/// comptime-false branch is not analysed.
const sys = @cImport({
    @cInclude("janet_features.h");
    @cInclude("sys/stat.h");
});

/// mingw and Darwin both translate this completely; only musl does not, and
/// the Linux arm never names it. On mingw `struct stat` and `struct
/// _stat64i32` are the same 48 bytes, which is the pairing the header itself
/// makes.
const Stat = sys.struct_stat;

/// The fields `os/stat` reports, in the order the numbers array holds them.
/// `os/fs/stat.zig` holds the keyword table that indexes it.
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

    pub const count = @typeInfo(Field).@"enum".fields.len;
};

/// `new_encode_dev`. The kernel packs a device number as twenty bits of major
/// above thirty-two, twelve more at bit eight, and the minor split either side
/// of it. glibc's `makedev` and musl's produce the same bits; this is not a
/// choice between conventions, it is the one encoding.
fn encodeDev(major: u32, minor: u32) u64 {
    return (@as(u64, major & 0xfffff000) << 32) |
        (@as(u64, major & 0x00000fff) << 8) |
        (@as(u64, minor & 0xffffff00) << 12) |
        @as(u64, minor & 0x000000ff);
}

// -------------------------------------------------------------- the Linux arm

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

// ------------------------------------------------- the macOS and Windows arm

fn readCStat(path: [*:0]const u8, do_lstat: bool, mode: *u32, numbers: [*]f64) i32 {
    var st: Stat = undefined;
    // Windows has no `lstat` and the C ignored `do_lstat` there too, so a
    // symlink is followed. It also takes the translated declaration rather than
    // the `@extern` below, because mingw has no renamed variants to choose
    // between and translate-c gives the right symbol directly.
    const res = if (windows)
        sys.stat(path, &st)
    else if (do_lstat)
        c_lstat(path, &st)
    else
        c_stat(path, &st);
    if (res == -1) return -1;

    zeroAll(numbers);
    mode.* = @intCast(st.st_mode);
    put(numbers, .dev, @floatFromInt(st.st_dev));
    put(numbers, .inode, @floatFromInt(st.st_ino));
    put(numbers, .uid, @floatFromInt(st.st_uid));
    put(numbers, .gid, @floatFromInt(st.st_gid));
    put(numbers, .nlink, @floatFromInt(st.st_nlink));
    put(numbers, .rdev, @floatFromInt(st.st_rdev));
    put(numbers, .size, @floatFromInt(st.st_size));
    // Darwin spells the three times as `st_atimespec` and reaches `st_atime`
    // through a macro, which translate-c does not carry across; Windows has
    // the plain `time_t` fields. Seconds either way, which is all `os/stat`
    // reports.
    if (windows) {
        put(numbers, .accessed, @floatFromInt(st.st_atime));
        put(numbers, .modified, @floatFromInt(st.st_mtime));
        put(numbers, .changed, @floatFromInt(st.st_ctime));
    } else {
        put(numbers, .accessed, @floatFromInt(st.st_atimespec.tv_sec));
        put(numbers, .modified, @floatFromInt(st.st_mtimespec.tv_sec));
        put(numbers, .changed, @floatFromInt(st.st_ctimespec.tv_sec));
    }
    // Two of the fifteen are never written on Windows, which is why the array
    // is zeroed before any of this: a descriptor's unwritten fields are part
    // of its contract and nothing about the type says so.
    if (!windows) {
        put(numbers, .blocks, @floatFromInt(st.st_blocks));
        put(numbers, .blocksize, @floatFromInt(st.st_blksize));
    }
    return 0;
}

// Declared rather than taken from `std.c`, which has no `stat` for
// `aarch64-macos` in 0.16: `std.stat` resolves to `private.stat`, and that
// member does not exist for this architecture. The symbol does.
//
// The *name* of the symbol is per-target. Darwin renamed these when it widened
// `ino_t`, and kept the old names bound to the old 32-bit structure for
// binaries built before the change; a 64-bit build asks for the suffixed ones
// on x86-64 and the plain ones on arm64, which is the same table `std.c`
// carries. Windows has the underscore spellings.
const stat_name = if (darwin_inode64) "stat$INODE64" else "stat";
const lstat_name = if (darwin_inode64) "lstat$INODE64" else "lstat";

const darwin_inode64 = switch (builtin.os.tag) {
    .macos, .ios, .tvos, .watchos, .visionos, .driverkit => builtin.cpu.arch == .x86_64,
    else => false,
};

const c_stat: *const fn ([*:0]const u8, *Stat) callconv(.c) c_int =
    @extern(*const fn ([*:0]const u8, *Stat) callconv(.c) c_int, .{ .name = stat_name });
const c_lstat: *const fn ([*:0]const u8, *Stat) callconv(.c) c_int =
    @extern(*const fn ([*:0]const u8, *Stat) callconv(.c) c_int, .{ .name = lstat_name });

inline fn put(numbers: [*]f64, field: Field, value: f64) void {
    numbers[@intFromEnum(field)] = value;
}

// ---------------------------------------------------------- the directory test

/// Whether an open stream is a directory, which `file/open` has to reject.
///
/// It is here rather than in `io.zig` for the reason the whole file exists: it
/// needs `struct stat`, and naming one is the thing that is per-platform.
///
/// Upstream ignores `fstat`'s result and reads the mode word regardless; that is
/// reproduced rather than repaired, because a failure leaves the buffer
/// uninitialised and the answer it then gives is whatever was on the stack.
/// `FOUND.md` has the entry. Zeroing first makes this answer determinate
/// without making it *different* on any path where Janet's was defined.
pub fn isDirectory(file: ?*anyopaque) bool {
    if (windows or builtin.os.tag == .plan9) return false;
    const fd = c.fileno(file);
    if (linux) {
        const l = std.os.linux;
        var stx: l.Statx = std.mem.zeroes(l.Statx);
        const rc = l.statx(fd, "", l.AT.EMPTY_PATH, l.STATX.BASIC_STATS, &stx);
        if (@as(isize, @bitCast(rc)) < 0) return false;
        return (stx.mode & S_IFMT) == S_IFDIR;
    }
    var st: Stat = std.mem.zeroes(Stat);
    _ = c_fstat(fd, &st);
    return (@as(u32, @intCast(st.st_mode)) & S_IFMT) == S_IFDIR;
}

const S_IFMT: u32 = 0o170000;
const S_IFDIR: u32 = 0o040000;

const fstat_name = if (darwin_inode64) "fstat$INODE64" else "fstat";
const c_fstat: *const fn (c_int, *Stat) callconv(.c) c_int =
    @extern(*const fn (c_int, *Stat) callconv(.c) c_int, .{ .name = fstat_name });

// ---------------------------------------------------------------- the abis

/// `janet_zig_os_stat_read`. Stat a path and copy out the mode word and one
/// double per numeric field. Every Janet value `os/stat` produces is built from
/// this.
pub fn statRead(path: [*:0]const u8, do_lstat: bool, mode: *u32, numbers: [*]f64) i32 {
    return if (linux)
        readStatx(path, do_lstat, mode, numbers)
    else
        readCStat(path, do_lstat, mode, numbers);
}

/// Zero every slot. Called *after* the syscall succeeds and never before,
/// which is Janet's order and is contract: `test/os_surface.zig` asserts that
/// a path that cannot be stat'ed leaves both `mode` and `numbers` untouched.
/// Zeroing first is the obvious way to write this and is wrong.
///
/// After success it is required: two slots are never written on Windows and
/// the Linux arm writes a different set again, and a descriptor's unwritten
/// fields are part of its contract with nothing about the type to say so.
inline fn zeroAll(numbers: [*]f64) void {
    for (0..Field.count) |i| numbers[i] = 0;
}
