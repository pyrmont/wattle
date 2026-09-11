//! `os/open`: a file opened as an event-loop stream.
//!
//! Out of the bucket for both of the split rule's reasons: `os/open` is a name
//! Janet publishes, and what it returns is a stream with a type of its own;
//! and the POSIX and Windows halves below exist because the platforms differ.
//! Both are compiled on every target so that the flag rules stay one subject
//! rather than two.
//!
//! The file is reached only under the event loop, because what it produces is
//! an `ev/stream.Stream`. Zig does not analyse a function nothing references,
//! so the registration table's comptime `if` is what keeps this out of a
//! `-Dev=false` build, where that type is not compiled at all.

// ==========================================================================
// Standard library imports
// ==========================================================================

const std = @import("std");
const builtin = @import("builtin");

// ==========================================================================
// Project imports
// ==========================================================================

const args_core = @import("../../args.zig");
const c = @import("cabi");
const ev_loop = @import("../../ev.zig");
const ev_stream = @import("../../ev/stream.zig");
const host = @import("host");
const oa = @import("../abi.zig");
const raise = @import("../../../api/raise.zig");
const repr = @import("repr");
const stat = @import("stat.zig");
const vm_lifecycle = @import("../../vm/lifecycle.zig");
const wrap = @import("../../value/helpers/wrap.zig");

/// `os/abi.zig`'s translation, which is where every `h.`-qualified constant
/// below comes from.
const h = oa.h;

// ==========================================================================
// Constants
// ==========================================================================

/// The two stream flags `ev.makeStream` takes, which say which halves of the
/// stream a caller asked for.
const stream_readable: u32 = 0x200;
const stream_writable: u32 = 0x400;

/// Whether this target takes the `CreateFileA` arm rather than the `open`
/// one.
const windows = builtin.os.tag == .windows;

// ==========================================================================
// Types
// ==========================================================================

/// What a flag scan reports back: the stream flags the letters asked for, and
/// whether a letter turned stream mode off.
///
/// The flag letters `os/open` accepts are two vocabularies, both compiled on
/// every target with only one reachable. The rule they implement belongs to
/// the host's `c.open` interface rather than to the machine running the build,
/// which is the same reason `os/process.zig` compiles the Windows command-line
/// escaping everywhere.
const OpenScan = struct {
    stream_flags: u32 = 0,
    disable_stream_mode: bool = false,
};

/// The six arguments `CreateFileA` takes, gathered by the Windows scan.
const WindowsOpen = struct {
    desired_access: u32 = 0,
    share_mode: u32 = 0,
    creation_disp: u32 = 0,
    file_flags: u32 = 0,
    file_attributes: u32 = 0,
    inherited_handle: bool = false,
};

// ==========================================================================
// Public functions
// ==========================================================================

/// `(os/open path &opt flags mode)`, which returns a stream rather than a
/// file.
pub fn cfunOpen(argv: []repr.Value) raise.Raising(repr.Value) {
    try args_core.arity(argv, 1, 3);
    const path = try args_core.getCString(argv, 0);
    const opt_flags: [*:0]const u8 = @ptrCast(try args_core.optKeyword(argv, 1, "r"));
    const mode = try stat.optMode(argv, 2, 0o666);
    var scan: OpenScan = .{};
    var fd: host.Handle = undefined;
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
        fd = c.retryIntr(c.open, .{ @as([*:0]const u8, @ptrCast(path)), open_flags, mode });
        if (fd == -1) return raise.panicv(ev_stream.evLasterr());
    }
    const flags = if (scan.disable_stream_mode) 0 else scan.stream_flags;
    return wrap.fromAbstract(try ev_loop.makeStream(fd, flags, null));
}

// ==========================================================================
// Private functions
// ==========================================================================

/// Reads the flag letters into the `open` flag word, asserting the sandbox
/// permission each letter implies as it is reached.
fn openPosix(opt_flags: [*:0]const u8, scan: *OpenScan) raise.Raising(c_int) {
    // Closed on exec, as every descriptor the runtime opens is.
    var open_flags: c_int = h.O_NONBLOCK | h.O_CLOEXEC;
    var read_flag = false;
    var write_flag = false;
    var i: usize = 0;
    while (opt_flags[i] != 0) : (i += 1) {
        switch (opt_flags[i]) {
            'r' => {
                read_flag = true;
                scan.stream_flags |= stream_readable;
                try vm_lifecycle.sandboxAssert(vm_lifecycle.Sandbox.of(&.{"fs_read"}));
            },
            'w' => {
                write_flag = true;
                scan.stream_flags |= stream_writable;
                try vm_lifecycle.sandboxAssert(vm_lifecycle.Sandbox.of(&.{"fs_write"}));
            },
            'c' => {
                open_flags |= h.O_CREAT;
                try vm_lifecycle.sandboxAssert(vm_lifecycle.Sandbox.of(&.{"fs_write"}));
            },
            'e' => open_flags |= h.O_EXCL,
            't' => {
                open_flags |= h.O_TRUNC;
                try vm_lifecycle.sandboxAssert(vm_lifecycle.Sandbox.of(&.{"fs_write"}));
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
    // A three-way fixup, and its last arm is one a caller depends on: neither
    // flag and both flags alike give `O_RDWR`.
    if (read_flag and !write_flag) {
        open_flags |= h.O_RDONLY;
    } else if (write_flag and !read_flag) {
        open_flags |= h.O_WRONLY;
    } else {
        open_flags |= h.O_RDWR;
    }
    return open_flags;
}

/// The same for `CreateFileA`, whose five words the letters are spread across.
/// The creation disposition is the one place the two interfaces do not line
/// up: POSIX combines `O_CREAT`, `O_EXCL` and `O_TRUNC` freely and Windows has
/// five named dispositions, so a combination outside those five is refused.
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
                try vm_lifecycle.sandboxAssert(vm_lifecycle.Sandbox.of(&.{"fs_read"}));
            },
            'w' => {
                w.desired_access |= h.GENERIC_WRITE;
                scan.stream_flags |= stream_writable;
                try vm_lifecycle.sandboxAssert(vm_lifecycle.Sandbox.of(&.{"fs_write"}));
            },
            'a' => {
                w.desired_access |= h.FILE_APPEND_DATA;
                scan.stream_flags |= stream_writable;
                try vm_lifecycle.sandboxAssert(vm_lifecycle.Sandbox.of(&.{"fs_write"}));
            },
            'c' => {
                creat_unix |= o_creat;
                try vm_lifecycle.sandboxAssert(vm_lifecycle.Sandbox.of(&.{"fs_write"}));
            },
            'e' => creat_unix |= o_excl,
            't' => {
                creat_unix |= o_trunc;
                try vm_lifecycle.sandboxAssert(vm_lifecycle.Sandbox.of(&.{"fs_write"}));
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
