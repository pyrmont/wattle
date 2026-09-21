//! `stat`, `lstat` and `fstat`, and the one place in this port where
//! `@cImport` does not serve.
//!
//! Host structures stay libc's, reached with `@cImport`. `struct stat` is the
//! single measured exception: musl declares `struct timespec` with a bitfield,
//! zero-width padding written as
//! `int :8*(sizeof(time_t)-sizeof(long))*(__BYTE_ORDER==4321)`, and
//! `translate-c` demotes any record with a bitfield in it to `opaque {}`.
//! `struct stat` embeds three timespecs, so it is demoted in turn and Zig can
//! neither size it nor place one on the stack. macOS and mingw translate it
//! completely, which is what makes the gap easy to miss.
//!
//! What replaces it, per platform:
//!
//! | platform | route |
//! | --- | --- |
//! | macOS, mingw | `@cImport`'s `struct stat`, which translates completely |
//! | Linux | `statx`, whose structure Zig defines itself |
//!
//! Zig's standard library supplies no substitute: `std.posix.Stat` is `void`
//! on Linux and Windows, 0.16 has no `std.posix.fstat`, `fstatat` or
//! `std.os.linux.Stat`, and `std.Io.File.Stat` has nine fields where `os/stat`
//! reports fifteen. What it does supply on Linux is `std.os.linux.Statx`,
//! which has every field `os/stat` needs.
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

/// A translation of `<sys/stat.h>` alone, and one of seven in the tree beside
/// `os/abi.h`, `net/abi.h`, `filewatch/abi.h`, `ev/locks.zig`, `host.zig` and
/// `cabi.zig`. A translation is right when nothing it declares crosses a
/// subsystem boundary, and nothing does: `struct stat` never leaves this file,
/// and what does leave is a mode word and an array of doubles.
///
/// It is translated on every target, including the musl ones where the result
/// is `opaque {}`. That is harmless because the Linux arm never names it, and
/// a comptime-false branch is not analysed.
const sys = @cImport({
    @cInclude("wattle_features.h");
    @cInclude("sys/stat.h");
});

// ==========================================================================
// Constants
// ==========================================================================

/// The file-type mask and the directory type, which is all of `<sys/stat.h>`'s
/// mode macros this file needs.
const S_IFDIR: u32 = 0o040000;
const S_IFMT: u32 = 0o170000;

/// `fstat`, `lstat` and `stat`, declared rather than taken from `std.c`, which
/// has no `stat` for `aarch64-macos` in 0.16: `std.stat` resolves to
/// `private.stat`, and that member does not exist for this architecture. The
/// symbol does.
const c_fstat: *const fn (c_int, *Stat) callconv(.c) c_int =
    @extern(*const fn (c_int, *Stat) callconv(.c) c_int, .{ .name = fstat_name });

const c_lstat: *const fn ([*:0]const u8, *Stat) callconv(.c) c_int =
    @extern(*const fn ([*:0]const u8, *Stat) callconv(.c) c_int, .{ .name = lstat_name });

const c_stat: *const fn ([*:0]const u8, *Stat) callconv(.c) c_int =
    @extern(*const fn ([*:0]const u8, *Stat) callconv(.c) c_int, .{ .name = stat_name });

/// Whether this target is the Darwin architecture whose plain `stat` symbol is
/// the pre-widening structure.
///
/// On x86-64 Darwin the plain names stayed bound to the 32-bit `ino_t`
/// structure and the wide one is `$INODE64`; arm64 has no such history, so
/// there the plain names are the wide structure. That is the same table
/// `std.c` has.
const darwin_inode64 = switch (builtin.os.tag) {
    .macos, .ios, .tvos, .watchos, .visionos, .driverkit => builtin.cpu.arch == .x86_64,
    else => false,
};

/// The three symbol names, which is where `darwin_inode64` is spent. Windows
/// takes the translated declaration instead and names none of them.
const fstat_name = if (darwin_inode64) "fstat$INODE64" else "fstat";

const lstat_name = if (darwin_inode64) "lstat$INODE64" else "lstat";

const stat_name = if (darwin_inode64) "stat$INODE64" else "stat";

/// Whether this target takes the `statx` arm, and whether it takes the arm
/// with no `lstat` at all.
const linux = builtin.os.tag == .linux;
const windows = builtin.os.tag == .windows;

// ==========================================================================
// Aliased types
// ==========================================================================

/// mingw and Darwin both translate this completely; only musl does not, and
/// the Linux arm never names it.
///
/// **Windows names `struct _stat64` rather than `struct stat`, and the reason
/// is a rename this import cannot see.** mingw picks both the layout and the
/// symbol from `_FILE_OFFSET_BITS`, which `wattle_features.h` sets to 64: the
/// struct gets a 64-bit `off_t`, and `stat` is declared
/// `__MINGW_ASM_CALL(stat64)` to match. `@cImport` does not carry an assembler
/// label across, so a call to `sys.stat` emits the plain `stat` symbol, which
/// fills the 48-byte `_stat64i32` layout instead. The mode word is at the same
/// offset in both and survives; `st_size` does not, and reads the access time.
/// Naming `_stat64` and `struct _stat64` pairs a symbol with the layout it
/// actually fills, neither of them renamed.
const Stat = if (windows) sys.struct__stat64 else sys.struct_stat;

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

    pub const count = @typeInfo(Field).@"enum".fields.len;
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
    if (windows or builtin.os.tag == .plan9) return false;
    return descriptorIsDirectory(c.fileno(file)) orelse false;
}

/// Whether an open descriptor is a directory, or null where the call failed.
/// `isDirectory` asks it of a stream's descriptor, and `filewatch.zig`'s
/// kqueue backend of each watched descriptor an event names, skipping an event
/// it cannot ask about. Windows and Plan 9 do not call it.
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
    return (@as(u32, @intCast(st.st_mode)) & S_IFMT) == S_IFDIR;
}

/// Stats a path and copies out the mode word and one double per numeric field.
/// Every Janet value `os/stat` produces is built from this.
pub fn statRead(path: [*:0]const u8, do_lstat: bool, mode: *u32, numbers: [*]f64) i32 {
    return if (linux)
        readStatx(path, do_lstat, mode, numbers)
    else
        readCStat(path, do_lstat, mode, numbers);
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
    numbers[@intFromEnum(field)] = value;
}

/// The macOS and Windows arm, over `struct stat`.
fn readCStat(path: [*:0]const u8, do_lstat: bool, mode: *u32, numbers: [*]f64) i32 {
    var st: Stat = undefined;
    // Windows has no `lstat`, so `do_lstat` is ignored there and a symlink is
    // followed. It takes the translated declaration rather than the `@extern`
    // below, and names the variant itself: mingw's `stat` is an assembler
    // label onto another symbol, which this import does not carry across.
    // `Stat` above has the whole of it.
    const res = if (windows)
        sys._stat64(path, &st)
    else if (do_lstat)
        c_lstat(path, &st)
    else
        c_stat(path, &st);
    if (res == -1) return -1;

    zeroAll(numbers);
    mode.* = @intCast(st.st_mode);
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
    // Darwin spells the three times as `st_atimespec`, and POSIX as `st_atim`;
    // each reaches `st_atime` through a macro, which translate-c does not
    // bring across. Windows has the plain `time_t` fields. Seconds either way,
    // which is all `os/stat` reports.
    if (windows) {
        put(numbers, .accessed, @floatFromInt(st.st_atime));
        put(numbers, .modified, @floatFromInt(st.st_mtime));
        put(numbers, .changed, @floatFromInt(st.st_ctime));
    } else if (builtin.os.tag.isDarwin()) {
        put(numbers, .accessed, @floatFromInt(st.st_atimespec.tv_sec));
        put(numbers, .modified, @floatFromInt(st.st_mtimespec.tv_sec));
        put(numbers, .changed, @floatFromInt(st.st_ctimespec.tv_sec));
    } else {
        put(numbers, .accessed, @floatFromInt(st.st_atim.tv_sec));
        put(numbers, .modified, @floatFromInt(st.st_mtim.tv_sec));
        put(numbers, .changed, @floatFromInt(st.st_ctim.tv_sec));
    }
    // Two of the fifteen are never written on Windows, and that is what the
    // zeroing above is for: a descriptor's unwritten fields are part of what a
    // caller reads, and nothing about the type says so.
    if (!windows) {
        put(numbers, .blocks, @floatFromInt(st.st_blocks));
        put(numbers, .blocksize, @floatFromInt(st.st_blksize));
    }
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
