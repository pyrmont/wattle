//! `os/open`: a file opened as an event-loop stream.
//!
//! Split out of `os_files.zig` at Phase 12 increment 6f. It stays out of the
//! bucket for `port/TREE.md`'s first reason -- `os/open` is a name Janet
//! publishes, and what it returns is a stream with a type of its own -- and
//! for its second: the POSIX and Windows halves below exist because the
//! platforms differ, and both are compiled on every target so the flag rules
//! stay one subject rather than two.

const std = @import("std");
const builtin = @import("builtin");
const types = @import("types");
const constants = @import("constants");
const c = @import("cabi");
const raise = @import("raise");
const args_core = @import("../../args.zig");
const ev_loop = @import("../../ev.zig");
const vm_lifecycle = @import("../../vm/lifecycle.zig");
const wrap = @import("../../value/helpers/wrap.zig");
const oa = @import("../abi.zig");
const h = oa.h;
const stat = @import("stat.zig");
const ev_stream = @import("../../ev/stream.zig");

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
                try vm_lifecycle.sandboxAssert(constants.JANET_SANDBOX_FS_READ);
            },
            'w' => {
                write_flag = true;
                scan.stream_flags |= stream_writable;
                try vm_lifecycle.sandboxAssert(constants.JANET_SANDBOX_FS_WRITE);
            },
            'c' => {
                open_flags |= h.O_CREAT;
                try vm_lifecycle.sandboxAssert(constants.JANET_SANDBOX_FS_WRITE);
            },
            'e' => open_flags |= h.O_EXCL,
            't' => {
                open_flags |= h.O_TRUNC;
                try vm_lifecycle.sandboxAssert(constants.JANET_SANDBOX_FS_WRITE);
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
                try vm_lifecycle.sandboxAssert(constants.JANET_SANDBOX_FS_READ);
            },
            'w' => {
                w.desired_access |= h.GENERIC_WRITE;
                scan.stream_flags |= stream_writable;
                try vm_lifecycle.sandboxAssert(constants.JANET_SANDBOX_FS_WRITE);
            },
            'a' => {
                w.desired_access |= h.FILE_APPEND_DATA;
                scan.stream_flags |= stream_writable;
                try vm_lifecycle.sandboxAssert(constants.JANET_SANDBOX_FS_WRITE);
            },
            'c' => {
                creat_unix |= o_creat;
                try vm_lifecycle.sandboxAssert(constants.JANET_SANDBOX_FS_WRITE);
            },
            'e' => creat_unix |= o_excl,
            't' => {
                creat_unix |= o_trunc;
                try vm_lifecycle.sandboxAssert(constants.JANET_SANDBOX_FS_WRITE);
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

pub fn openImpl(argv: []types.Janet) raise.Raising(types.Janet) {
    try args_core.arity(argv, 1, 3);
    const path = try args_core.getCString(argv, 0);
    const opt_flags: [*:0]const u8 = @ptrCast(try args_core.optKeyword(argv, 1, "r"));
    const mode = try stat.optMode(argv, 2, 0o666);
    var scan: OpenScan = .{};
    var fd: types.JanetHandle = undefined;
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
        if (fd == h.INVALID_HANDLE_VALUE) return raise.panicv(ev_stream.evLasterr());
    } else {
        const open_flags = try openPosix(opt_flags, &scan);
        while (true) {
            fd = open(@ptrCast(path), open_flags, mode);
            if (!(fd == -1 and errno() == h.EINTR)) break;
        }
        if (fd == -1) return raise.panicv(ev_stream.evLasterr());
    }
    const flags = if (scan.disable_stream_mode) 0 else scan.stream_flags;
    return wrap.fromAbstract(try ev_loop.makeStream(fd, flags, null));
}

const windows = builtin.os.tag == .windows;

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
