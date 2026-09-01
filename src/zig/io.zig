//! Files: the `core/file` abstract type and its five callbacks, the
//! twenty-two cfunctions of the `file/` and `print`/`printf` families, the
//! eight public `JanetFile` entry points, the mode-string kernels, the stream
//! host operations, and the registration.
//!
//! ## The raise shape
//!
//! Every `janet_panic` Janet writes is an error return here: a cfunction that
//! decides to raise returns `raise.Raising(Value)`, and one that makes no such
//! decision is written as the plain `raise.CFunction` it is. Twenty of the
//! twenty-two raise; the two that cannot are `flush` and `eflush`, whose three
//! arms are "flush it", "flush the default handle" and "do nothing".
//!
//! One consequence is visible in `printfImplX`: Janet builds a scratch buffer,
//! formats into it, and frees its backing store by hand, and a raise inside
//! the formatting skips that free. This reproduces that rather than repairing
//! it -- nothing leaks either way, because scratch memory is reclaimed by the
//! next collection.
//!
//! ## `FILE`, and the one structure this file will not read
//!
//! `FILE` is opaque by definition, so a stream crosses the kernel boundary as a
//! handle rather than as a structure. There is one spelling of it, `host.FILE`,
//! for the reason `host.zig` gives: two declarations of a host type in one
//! program is a silent mismatch rather than a compile error.
//!
//! `struct stat` is the one this file does not read. `file/open` rejects a
//! directory by `fstat`ing the descriptor it just opened, `std.fstat` is `{}`
//! on Linux and `std.Stat` has no Linux arm, and the two ways a Zig frame could
//! get one anyway are both refused elsewhere in this tree: a second `@cImport`
//! over `<sys/stat.h>` is the duplicate translation the single-translation rule
//! prevents, and a hand-written layout per platform is guesswork. So the test
//! lives in `os/fs/host_stat.zig`, beside the other reader of a host stat
//! structure, and this file imports it.
//!
//! The marshalling path reaches a descriptor, through `c.dup` and `c.fdopen`.
//! Plan 9 spells `c.dup` with two arguments; there is no Zig target for Plan 9
//! in this project, so that branch is recorded here and not written.

const std = @import("std");
const builtin = @import("builtin");
const repr = @import("repr");
const corefn = @import("corefn.zig");
const raise = @import("raise.zig");
const registry = @import("registry.zig");
const constants = @import("constants");
const c = @import("cabi");
const stdio = @import("stdio.zig");
const pp_describe = @import("pp.zig");
const vm_lifecycle = @import("vm/lifecycle.zig");
const vm_state = @import("vm/state.zig");
const marsh = @import("marsh.zig");
const pp_format = @import("pp/format.zig");
const vm_entry = @import("vm/entry.zig");
const abstract_type = @import("abstract_type.zig");
const method_type = @import("method_type.zig");
const utils = @import("utils.zig");
const wrap = @import("value/helpers/wrap.zig");
const args_core = @import("args.zig");
const buffers = @import("value/buffers.zig");
const abstracts = @import("value/abstracts.zig");
const strings = @import("value/strings.zig");

const windows = builtin.os.tag == .windows;

/// The four flags the mode scanner produces, and the two the abstract carries
/// beside them. The rest are with the abstract type below.
const file_write: i32 = 1;
const file_read: i32 = 2;
const file_append: i32 = 4;
const file_update: i32 = 8;
const file_binary: i32 = 64;
const file_nonil: i32 = 512;

// The sandbox flags this file reports are `vm_lifecycle.Sandbox`'s members
// rather than bare numbers restated here. Restated numbers are invisible to
// every instrument in the tree and would survive a change to their values.

/// What `scanMode` reports. This is the only place these codes are written
/// down; `test/io_core.zig` names them rather than restating the numbers.
pub const mode_ok: i32 = 0;
pub const mode_bad_length: i32 = 1;
pub const mode_bad_first: i32 = 2;
pub const mode_bad_later: i32 = 3;
pub const mode_repeated: i32 = 4;

/// `SEEK_SET`, `SEEK_CUR`, and `SEEK_END` are 0, 1, and 2 on every platform
/// Janet builds for, but they are host constants, so the boundary carries the
/// position of the keyword in `whence_names` instead and the mapping happens
/// here.
const seek_set: c_int = 0;
const seek_cur: c_int = 1;
const seek_end: c_int = 2;

/// `_IONBF` is 2 in the POSIX C libraries and 4 in the Microsoft one.
const iofbf: c_int = 0;
const ionbf: c_int = if (windows) 4 else 2;

/// The single fd flag POSIX defines.
const fd_cloexec: c_int = 1;

/// libc's `FILE`, from `host.zig` rather than declared again here.
///
/// A local `opaque {}` gave the tree **two** `FILE` types once. Both are opaque
/// and so ABI-identical, and nothing could go wrong at runtime -- but they are
/// distinct Zig types, and one declaration against the other is the mismatch
/// `cabi_check.zig` exists to find.
pub const FILE = host.FILE;

// The sixteen stream kernels below are ordinary Zig functions. Each wraps one
// libc call, so that the twenty-two cfunctions above hold a `?*FILE` and the
// Windows arm of a call is written once.

/// Classify a `file/open` mode string.
///
/// Reports the flag word, the sandbox permissions the accepted prefix implies,
/// and where the scan stopped. **Ordering matters**: the caller asserts the
/// permissions and then raises, so the permissions accumulate only over the
/// bytes reached before the scan stopped — a sandbox denial for a prefix comes
/// out before the complaint about a later bad byte.
///
/// A repeated flag yields a flag word of -1, which the caller then uses as a
/// flag word. `FOUND.md` records that and it is reproduced rather than fixed.
pub fn scanMode(
    mode: [*]const u8,
    len: usize,
    flags_out: *i32,
    sandbox_out: *vm_lifecycle.Sandbox,
    index_out: *i32,
) i32 {
    flags_out.* = 0;
    sandbox_out.* = vm_lifecycle.Sandbox.none;
    index_out.* = 0;
    if (len < 1 or len > 10) return mode_bad_length;

    var flags: i32 = 0;
    switch (mode[0]) {
        'w' => {
            flags |= file_write;
            sandbox_out.* = sandbox_out.with(vm_lifecycle.Sandbox.of(&.{"fs_write"}));
        },
        'a' => {
            flags |= file_append;
            sandbox_out.* = sandbox_out.with(vm_lifecycle.Sandbox.fs);
        },
        'r' => {
            flags |= file_read;
            sandbox_out.* = sandbox_out.with(vm_lifecycle.Sandbox.of(&.{"fs_read"}));
        },
        else => return mode_bad_first,
    }

    for (mode[1..len], 1..) |byte, index| {
        index_out.* = @intCast(index);
        switch (byte) {
            '+' => {
                if (flags & file_update != 0) return repeated(flags_out);
                sandbox_out.* = sandbox_out.with(vm_lifecycle.Sandbox.of(&.{"fs_write"}));
                flags |= file_update;
            },
            'b' => {
                if (flags & file_binary != 0) return repeated(flags_out);
                flags |= file_binary;
            },
            'n' => {
                if (flags & file_nonil != 0) return repeated(flags_out);
                flags |= file_nonil;
            },
            else => return mode_bad_later,
        }
    }

    flags_out.* = flags;
    return mode_ok;
}

fn repeated(flags_out: *i32) i32 {
    flags_out.* = -1;
    return mode_repeated;
}

const whence_names = [_][:0]const u8{ "cur", "set", "end" };

/// Find a seek origin by keyword, returning its position or -1.
///
/// The comparison reproduces `janet_cstrcmp`, which the C implementation used
/// here, including its treatment of a key whose own bytes end in NUL.
pub fn seekWhence(key: [*]const u8, len: usize) i32 {
    for (whence_names, 0..) |name, index| {
        if (cstrequal(key, len, name)) return @intCast(index);
    }
    return -1;
}

fn cstrequal(key: [*]const u8, len: usize, other: [:0]const u8) bool {
    var index: usize = 0;
    while (index < len) : (index += 1) {
        const k = other.ptr[index];
        if (key[index] != k) return false;
        if (k == 0) break;
    }
    return other.ptr[index] == 0;
}

/// Rebuild the `c.fopen` mode a flag word came from, for reattaching a marshalled
/// descriptor. Writes at most three bytes plus a terminator into `out` and
/// returns the length.
///
/// This is not the inverse of `scanMode`: it drops the binary, update, and
/// no-nil flags, and it collapses append and write, because the C
/// implementation only needed a mode `c.fdopen` would accept.
pub fn modeFromFlags(flags: i32, out: *[4]u8) i32 {
    out.* = .{ 0, 0, 0, 0 };
    var len: usize = 0;
    if (flags & file_read != 0) {
        out[len] = 'r';
        len += 1;
    }
    if (flags & file_append != 0) {
        out[len] = 'a';
        len += 1;
    } else if (flags & file_write != 0) {
        out[len] = 'w';
        len += 1;
    }
    return @intCast(len);
}

pub fn open(path: [*:0]const u8, mode: [*:0]const u8) ?*FILE {
    return c.fopen(path, mode);
}

pub fn temp() ?*FILE {
    return c.tmpfile();
}

/// Each host operation is written once over a stream and exported once over a
/// handle. The seam carries a `void *` because a `FILE` is opaque by
/// definition, and every caller inside this file has a `JanetFile` and
/// therefore a stream already.
///
/// The stream is optional throughout. A closed `JanetFile` holds a null, and
/// two of the paths below can be reached with one: `c.fflush(NULL)` flushes
/// every output stream in the process, and `c.setvbuf(NULL, ...)` is undefined.
/// Both are recorded in `FOUND.md` and reproduced rather than trapped on,
/// which is only possible if the null travels as a null instead of through a
/// checked cast.
pub fn close(file: ?*FILE) i32 {
    return c.fclose(file);
}

pub fn flush(file: ?*FILE) i32 {
    return c.fflush(file);
}

/// Read up to `count` bytes, reporting how many arrived. A short read is not by
/// itself a failure, which is why a caller consults `err` afterwards.
pub fn read(file: ?*FILE, dest: [*]u8, count: usize) usize {
    return c.fread(dest, 1, count, file);
}

/// Write `count` bytes as a single item, so the result is 1 on success and 0 on
/// failure. Callers compare against 1, as the C original did with `c.fwrite`
/// directly.
/// The three standard streams as this file's `FILE`, which is `host.FILE`
/// under another name. `stdio.zig` answers the same type; these three exist so
/// the dozen registration rows below name one thing.
fn stdinFile() ?*FILE {
    return stdio.in();
}
fn stdoutFile() ?*FILE {
    return stdio.out();
}
fn stderrFile() ?*FILE {
    return stdio.err();
}

pub fn write(file: ?*FILE, src: [*]const u8, count: usize) i32 {
    return @intCast(c.fwrite(src, count, 1, file));
}

/// Read one byte, or return `EOF`.
pub fn getChar(file: ?*FILE) i32 {
    return c.fgetc(file);
}

pub fn putChar(file: ?*FILE, ch: i32) i32 {
    return c.fputc(ch, file);
}

pub fn err(file: ?*FILE) i32 {
    return c.ferror(file);
}

/// Select full buffering of `size` bytes, or no buffering when `size` is zero.
pub fn setBufferSize(file: ?*FILE, size: usize) i32 {
    return c.setvbuf(file, null, if (size != 0) iofbf else ionbf, size);
}

/// Move the file position, with `whence` given as a position in
/// `whence_names`. An unrecognized origin cannot reach here: a caller rejects
/// it while it still holds the keyword to name in the panic.
pub fn seek(file: ?*FILE, offset: i64, whence: i32) i32 {
    const origin: c_int = switch (whence) {
        0 => seek_cur,
        1 => seek_set,
        else => seek_end,
    };
    if (windows) return c._fseeki64(file, offset, origin);
    // A 32-bit `long` narrows the offset here exactly as the C
    // implementation's implicit conversion did; `FOUND.md` records what that
    // costs a 32-bit host.
    return c.fseek(file, @truncate(offset), origin);
}

pub fn tell(file: ?*FILE) i64 {
    if (windows) return c._ftelli64(file);
    return c.ftell(file);
}

/// Close the stream's descriptor across an exec. `c.fopen` has no standard flag
/// for this, which is why Janet sets it separately.
///
/// There is no handle-taking abi over it. There was, with no caller, and an
/// `@export` with no caller links forever without anything saying so.
fn setCloexecStream(file: ?*FILE) i32 {
    return std.c.fcntl(c.fileno(file), std.c.F.SETFD, fd_cloexec);
}

// ==========================================================================
// The `core/file` abstract type
// ==========================================================================

/// The flags the abstract type carries that a mode string cannot ask for. The
/// four the mode scanner produces are above.
const file_not_closeable: i32 = 16;
const file_closed: i32 = 32;
const file_serializable: i32 = 128;

/// Whether this is a Plan 9 build. `c.dup` takes a second argument there and
/// `c.fopen` needs no close-on-exec fixup; both branches are unreachable from
/// Zig, because Plan 9 is not one of this project's targets, and are recorded
/// rather than written. `math.zig` reads its own gate the same way.
const plan9 = (builtin.os.tag == .plan9);

/// The C library's default buffer size, which `file/open` compares against to
/// decide whether the caller asked for a different one.
const bufsiz: usize = c.BUFSIZ;

const eof: i32 = c.EOF;

/// The directory test, which needs `struct stat` and therefore lives with the
/// other host-structure reader, `os/fs/host_stat.zig`. This file imports it.
const host_stat = @import("os/fs/host_stat.zig");
const abi = @import("abi");
const tables = @import("value/tables.zig");
const host = @import("host");

/// The stream a `File` holds.
///
/// A named accessor rather than the field, because the two of these are the
/// only places that know the field's spelling: the abstract's payload is
/// reached through it at forty sites and a change to how a stream is stored
/// stops here.
inline fn streamOf(iof: *File) ?*FILE {
    return iof.file;
}

/// Store a stream into a `File`, the inverse of `streamOf`.
inline fn setStreamOf(iof: *File, file: ?*FILE) void {
    iof.file = file;
}

/// The one path that holds a stream as the seam's `void *`
/// rather than as a `JanetFile`: `file/open` has to `fstat` and possibly
/// `c.fclose` its result before there is a payload to put it in.
inline fn streamOfHandle(handle: *anyopaque) ?*FILE {
    return @ptrCast(handle);
}

fn getFile(argv: []repr.Value, n: usize) raise.Raising(*File) {
    return try args_core.getAbstract(File, argv, n, &fileType);
}

/// `JANET_EXIT`, which `janet_assert` expands to. A macro, so no translation
/// ever carried it.
///
/// Two things here are not the C original's. The location reported is this
/// file's rather than the C original's, and an embedder's own `JANET_EXIT` is
/// a preprocessor override that no Zig caller can see. The message is
/// assembled at compile time and written with
/// `c.fwrite` rather than handed to `fprintf`, because `fprintf` takes the
/// *translated* `FILE *` and this file deliberately does not name that type.
fn exitWith(comptime where: std.builtin.SourceLocation, comptime message: []const u8) noreturn {
    const line = std.fmt.comptimePrint(
        "janet abort at {s}:{d}: {s}\n",
        .{ where.file, where.line, message },
    );
    _ = write(stderrFile(), line.ptr, line.len);
    c.abort();
}

fn fileGC(iof: *File, _: usize) void {
    _ = closeFile(iof);
}

fn fileGet(_: *File, key: repr.Value) raise.Raising(?repr.Value) {
    return args_core.findMethod(key, @ptrCast(&file_methods));
}

fn fileNext(_: *File, key: repr.Value) raise.Raising(repr.Value) {
    return args_core.nextmethod(@ptrCast(&file_methods), key);
}

/// Write a live descriptor into the stream, which only an unsafe marshal may
/// do. A closeable file is duplicated so that the marshalled copy owns its own
/// descriptor; a borrowed one -- `stdout` and its kin -- is written as it
/// stands.
fn fileMarshal(iof: *File, ctx: *abi.MarshalContext) raise.Raising(void) {
    if (marsh.marshalFlags(ctx) & constants.JANET_MARSHAL_UNSAFE == 0) {
        return raise.panic("cannot marshal file in safe mode");
    }
    marsh.marshalAbstract(ctx, iof);
    const borrowed = iof.flags & file_not_closeable != 0;
    const fno: c_int = if (windows)
        (if (borrowed) c._fileno(streamOf(iof)) else c._dup(c._fileno(streamOf(iof))))
    else
        (if (borrowed) c.fileno(streamOf(iof)) else c.dup(c.fileno(streamOf(iof))));
    try marsh.marshalInt(ctx, @intCast(fno));
    try marsh.marshalInt(ctx, iof.flags);
    try marsh.marshalSize(ctx, iof.vbufsize);
}

/// Reattach a descriptor read back out of a stream.
///
/// The mode is rebuilt from the flag word rather than carried, which is why
/// `modeFromFlags` is not the inverse of `scanMode`: `c.fdopen` only has to
/// accept it.
fn fileUnmarshal(ctx: *abi.MarshalContext) raise.Raising(*File) {
    if (marsh.unmarshalFlags(ctx) & constants.JANET_MARSHAL_UNSAFE == 0) {
        return raise.panic("cannot unmarshal file in safe mode");
    }
    const iof: *File = @ptrCast(@alignCast(try marsh.unmarshalAbstract(ctx, @sizeOf(File))));
    const fd = try marsh.unmarshalInt(ctx);
    const flags = try marsh.unmarshalInt(ctx);
    var fmt: [4]u8 = undefined;
    _ = modeFromFlags(flags, &fmt);
    const reopened = if (windows) c._fdopen(fd, @ptrCast(&fmt)) else c.fdopen(fd, @ptrCast(&fmt));
    setStreamOf(iof, reopened);
    iof.flags = if (reopened == null) file_closed else flags;
    iof.vbufsize = try marsh.unmarshalSize(ctx);
    if (iof.vbufsize != bufsiz) {
        if (setBufferSize(reopened, iof.vbufsize) != 0) {
            exitWith(@src(), "unmarshal setvbuf");
        }
    }
    return iof;
}

pub const fileType = abstract_type.define(File, .{
    .name = "core/file",
    .gc = fileGC,
    .get = fileGet,
    .marshal = fileMarshal,
    .unmarshal = fileUnmarshal,
    .next = fileNext,
});

// ==========================================================================
// Opening, and the checks around it
// ==========================================================================

/// Scan an `file/open` mode string and raise what it reports.
///
/// The interleaving is the C original's and matters: the permissions the
/// accepted prefix implies are asserted *before* a later bad flag is reported,
/// so a sandboxed build refuses `:wq` for the sandbox rather than for the `q`.
fn checkFlags(str: strings.String) raise.Raising(i32) {
    var flags: i32 = 0;
    var sandbox_flags: vm_lifecycle.Sandbox = .{};
    var index: i32 = 0;
    const status = scanMode(str, strings.head(str).length, &flags, &sandbox_flags, &index);
    if (status == mode_bad_length) {
        return raise.panic("file mode must have a length between 1 and 10");
    }
    if (status == mode_bad_first) {
        return pp_format.panicf("invalid flag %c, expected w, a, or r", .{@as(c_int, str[@intCast(index)])});
    }
    try vm_lifecycle.sandboxAssert(sandbox_flags);
    if (status == mode_bad_later) {
        return pp_format.panicf("invalid flag %c, expected +, b, or n", .{@as(c_int, str[@intCast(index)])});
    }
    return flags;
}

/// Wrap a stream in the abstract that owns it.
///
/// `c.fopen` has no standard way to ask for close-on-exec -- the `e` mode flag
/// is a GNU extension -- so a file this runtime will close is marked
/// separately, and one it only borrows is left alone.
fn makef(f: ?*FILE, flags: i32, bufsize: usize) *File {
    const iof: *File = abstracts.newFor(File, &fileType);
    setStreamOf(iof, f);
    iof.flags = flags;
    iof.vbufsize = bufsize;
    if (!windows and !plan9) {
        if (flags & file_not_closeable == 0) _ = setCloexecStream(f);
    }
    return iof;
}

fn cfunTemp(argv: []repr.Value) align(corefn.alignment) raise.Raising(repr.Value) {
    try vm_lifecycle.sandboxAssert(vm_lifecycle.Sandbox.of(&.{"fs_temp"}));

    try args_core.fixarity(argv, 0);
    // XXX use mkostemp when we can to avoid CLOEXEC race.
    const tmp = temp() orelse {
        return pp_format.panicf("unable to create temporary file - %s", .{utils.strerrorSafe(c.errno())});
    };
    return makefile(@ptrCast(tmp), file_write | file_read | file_binary);
}

fn cfunFopen(argv: []repr.Value) align(corefn.alignment) raise.Raising(repr.Value) {
    try args_core.arity(argv, 1, 3);
    const fname = try args_core.getString(argv, 0);
    var fmode: strings.String = undefined;
    var flags: i32 = undefined;
    // A third argument leaves the mode unscanned and the file read-only; that
    // is the C original's `argc == 2` and is recorded in `FOUND.md`.
    if (argv.len == 2) {
        fmode = try args_core.getKeyword(argv, 1);
        flags = try checkFlags(fmode);
    } else {
        fmode = @ptrCast("r");
        try vm_lifecycle.sandboxAssert(vm_lifecycle.Sandbox.of(&.{"fs_read"}));
        flags = file_read;
    }
    const f = open(@ptrCast(fname), @ptrCast(fmode));
    var bufsize: usize = bufsiz;
    if (f) |handle| {
        // A directory that `c.fopen` accepted is rejected here. The test is
        // `host_stat.zig`'s rather than this file's: see the note there for
        // why a `struct stat` is read in one place for all four targets.
        if (host_stat.isDirectory(handle)) {
            _ = close(streamOfHandle(handle));
            return pp_format.panicf("cannot open directory: %s", .{fname});
        }
        bufsize = try args_core.optSize(argv, 2, bufsiz);
        if (bufsize != bufsiz) {
            if (setBufferSize(streamOfHandle(handle), bufsize) != 0) {
                return raise.panic("failed to set buffer size for file");
            }
        }
    }
    if (f) |handle| return wrap.fromAbstract(makef(@ptrCast(handle), flags, bufsize));
    if (flags & file_nonil != 0) {
        return pp_format.panicf("failed to open file %s: %s", .{ fname, utils.strerrorSafe(c.errno()) });
    }
    return wrap.fromNil();
}

// ==========================================================================
// Reading, writing, and positioning
// ==========================================================================

/// Read up to `n_bytes_max` bytes onto the end of `buffer`.
///
/// A short read is not by itself a failure -- it is how the end of the file is
/// reached -- so the error indicator decides.
fn readChunk(iof: *File, buffer: *buffers.Buffer, n_bytes_max: usize) raise.Raising(void) {
    if (iof.flags & (file_read | file_update) == 0) {
        return raise.panic("file is not readable");
    }
    try buffers.extra(buffer, n_bytes_max);
    const nread = read(streamOf(iof), buffer.data.? + buffer.count, n_bytes_max);
    if (nread != n_bytes_max and err(streamOf(iof)) != 0) {
        return raise.panic("could not read file");
    }
    buffer.count += @intCast(nread);
}

fn cfunFread(argv: []repr.Value) align(corefn.alignment) raise.Raising(repr.Value) {
    try args_core.arity(argv, 2, 3);
    const iof = try getFile(argv, 0);
    if (iof.flags & file_closed != 0) return raise.panic("file is closed");
    const buffer = if (argv.len == 2) buffers.new(0) else try args_core.getBuffer(argv, 2);
    const bufstart = buffer.count;
    if (repr.checkType(argv[1], repr.Tag.keyword)) {
        const sym = wrap.toKeyword(argv[1]);
        if (utils.cstrcmp(sym, "all") == 0) {
            var size_before: i32 = undefined;
            while (true) {
                size_before = @intCast(buffer.count);
                try readChunk(iof, buffer, 4096);
                if (size_before >= buffer.count) break;
            }
            // Never return nil for :all
            return wrap.fromBuffer(buffer);
        } else if (utils.cstrcmp(sym, "line") == 0) {
            while (true) {
                const x = getChar(streamOf(iof));
                if (x != eof) try buffers.pushU8(buffer, @intCast(x));
                if (x == eof or x == '\n') break;
            }
        } else {
            return pp_format.panicf("expected one of :all, :line, got %v", .{argv[1]});
        }
    } else {
        const len = try args_core.getInteger(argv, 1);
        if (len < 0) return raise.panic("expected positive integer");
        try readChunk(iof, buffer, @intCast(len));
    }
    if (bufstart == buffer.count) return wrap.fromNil();
    return wrap.fromBuffer(buffer);
}

fn cfunFwrite(argv: []repr.Value) align(corefn.alignment) raise.Raising(repr.Value) {
    try args_core.arity(argv, 1, -1);
    const iof = try getFile(argv, 0);
    if (iof.flags & file_closed != 0) return raise.panic("file is closed");
    if (iof.flags & (file_write | file_append | file_update) == 0) {
        return raise.panic("file is not writeable");
    }
    // Verify all arguments before writing to file
    for (1..argv.len) |i| _ = try args_core.getBytes(argv, i);
    for (1..argv.len) |i| {
        const view = try args_core.getBytes(argv, i);
        if (view.len != 0) {
            if (write(streamOf(iof), args_core.viewBytes(view).ptr, @intCast(view.len)) == 0) {
                return raise.panic("error writing to file");
            }
        }
    }
    return argv[0];
}

// `dynprintf` lives in `pp/format.zig`, beside the engine. Its format string
// is `comptime`, so a caller instantiates it rather than calling it, and a
// *contract* for it has to be compiled beside the engine; keeping it here
// would have meant compiling all of this file into that contract's module.
// What it needs from here -- this check, `write` and `fileType` -- it reaches
// by `@import`, so the check's raise is a returned error at the call site.

pub fn assertWriteable(iof: *File) raise.Raising(void) {
    if (iof.flags & file_closed != 0) return raise.panic("file is closed");
    if (iof.flags & (file_write | file_append | file_update) == 0) {
        return raise.panic("file is not writeable");
    }
}

fn cfunFflush(argv: []repr.Value) align(corefn.alignment) raise.Raising(repr.Value) {
    try args_core.fixarity(argv, 1);
    const iof = try getFile(argv, 0);
    try assertWriteable(iof);
    if (flush(streamOf(iof)) != 0) return raise.panic("could not flush file");
    return argv[0];
}

/// Close a file from the C API, reporting the host's result.
///
/// A file that is already closed, or that this runtime only borrowed, reports
/// success and is left alone. The stream pointer is cleared on the way out:
/// the C original's comment says a null dereference is easier to debug than
/// the alternative.
fn closeFile(file: *File) c_int {
    if (file.flags & (file_not_closeable | file_closed) == 0) {
        const ret = close(streamOf(file));
        file.flags |= file_closed;
        file.file = null;
        return ret;
    }
    return 0;
}

pub fn fileClose(file: *File) c_int {
    return closeFile(file);
}

fn cfunFclose(argv: []repr.Value) align(corefn.alignment) raise.Raising(repr.Value) {
    try args_core.fixarity(argv, 1);
    const iof = try getFile(argv, 0);
    if (iof.flags & file_closed != 0) return wrap.fromNil();
    if (iof.flags & file_not_closeable != 0) return raise.panic("file not closable");
    if (close(streamOf(iof)) != 0) {
        iof.flags |= file_not_closeable;
        return raise.panic("could not close file");
    }
    iof.flags |= file_closed;
    return wrap.fromNil();
}

fn cfunFseek(argv: []repr.Value) align(corefn.alignment) raise.Raising(repr.Value) {
    try args_core.arity(argv, 2, 3);
    const iof = try getFile(argv, 0);
    if (iof.flags & file_closed != 0) return raise.panic("file is closed");
    var offset: i64 = 0;
    // The arity above makes the C original's `argc >= 2` test always true.
    const whence_sym = try args_core.getKeyword(argv, 1);
    const whence = seekWhence(whence_sym, strings.head(whence_sym).length);
    if (whence < 0) {
        return pp_format.panicf("expected one of :cur, :set, :end, got %v", .{argv[1]});
    }
    if (argv.len == 3) offset = try args_core.getInteger64(argv, 2);
    if (seek(streamOf(iof), offset, whence) != 0) return raise.panic("error seeking file");
    return argv[0];
}

fn cfunFtell(argv: []repr.Value) align(corefn.alignment) raise.Raising(repr.Value) {
    try args_core.fixarity(argv, 1);
    const iof = try getFile(argv, 0);
    if (iof.flags & file_closed != 0) return raise.panic("file is closed");
    const pos = tell(streamOf(iof));
    if (pos == -1) return raise.panic("error getting position in file");
    return wrap.fromNumber(@floatFromInt(pos));
}

/// The method table `(:read f ...)` and `(keys f)` both walk.
///
/// `janet_getmethod` scans it linearly, so the order is what `janet_nextmethod`
/// reports and is part of the contract rather than a tidiness.
const file_methods = [_]method_type.Method{
    .{ .name = "close", .cfun = cfunFclose },
    .{ .name = "flush", .cfun = cfunFflush },
    .{ .name = "read", .cfun = cfunFread },
    .{ .name = "seek", .cfun = cfunFseek },
    .{ .name = "tell", .cfun = cfunFtell },
    .{ .name = "write", .cfun = cfunFwrite },
    .{ .name = null, .cfun = null },
};

// ==========================================================================
// The print families
// ==========================================================================

pub fn dynfile(name: [*:0]const u8, def: ?*FILE) ?*FILE {
    const x = vm_state.dyn(name);
    if (!repr.checkType(x, repr.Tag.abstract)) return def;
    const abstract = wrap.toAbstract(x);
    if (abi.abstractHead(abstract).type != &fileType) return def;
    const iof: *File = @ptrCast(@alignCast(abstract));
    return @ptrCast(iof.file);
}

/// Print `argv[offset..]` to `x`, which may be a buffer, a function, a file,
/// or nil for the default handle.
///
/// An abstract that is not a file is silently ignored -- it returns nil having
/// printed nothing -- which is the C original's and is why the `default` arm
/// below cannot simply own every non-file case.
fn printImplX(
    argv: []repr.Value,
    newline: bool,
    dflt_file: ?*FILE,
    offset: usize,
    x: repr.Value,
) raise.Raising(repr.Value) {
    var f: ?*FILE = null;
    switch (repr.typeOf(x)) {
        repr.Tag.buffer => {
            // Special case buffer
            const buf = wrap.toBuffer(x);
            for (argv[offset..]) |arg| try pp_describe.toStringB(buf, arg);
            if (newline) try buffers.pushU8(buf, '\n');
            return wrap.fromNil();
        },
        repr.Tag.function => {
            // Special case function
            const fun = wrap.toFunction(x);
            const buf = buffers.new(0);
            for (argv[offset..]) |arg| try pp_describe.toStringB(buf, arg);
            if (newline) try buffers.pushU8(buf, '\n');
            var args = [_]repr.Value{wrap.fromBuffer(buf)};
            _ = try vm_entry.call(fun, (&args)[0..1]);
            return wrap.fromNil();
        },
        repr.Tag.nil => {
            f = dflt_file;
            if (f == null) return raise.panic("cannot print to nil");
        },
        repr.Tag.abstract => {
            const abstract = wrap.toAbstract(x);
            if (abi.abstractHead(abstract).type != &fileType) return wrap.fromNil();
            const iofile: *File = @ptrCast(@alignCast(abstract));
            try assertWriteable(iofile);
            f = streamOf(iofile);
        },
        else => return pp_format.panicf("cannot print to %v", .{x}),
    }
    for (argv[offset..]) |arg| {
        var len: i32 = undefined;
        var vstr: [*]const u8 = undefined;
        if (repr.checkType(arg, repr.Tag.buffer)) {
            const b = wrap.toBuffer(arg);
            vstr = b.data.?;
            len = @intCast(b.count);
        } else {
            vstr = pp_describe.toString(arg);
            // `len` stays `i32` because the two failure messages below hand it
            // to `%d`, which reads a 32-bit argument.
            len = @intCast(strings.head(vstr).length);
        }
        if (len != 0) {
            if (write(f, vstr, @intCast(len)) != 1) {
                if (f == dflt_file) {
                    return pp_format.panicf("cannot print %d bytes", .{len});
                } else {
                    return pp_format.panicf("cannot print %d bytes to %v", .{ len, x });
                }
            }
        }
    }
    if (newline) _ = putChar(f, '\n');
    return wrap.fromNil();
}

fn print(
    argv: []repr.Value,
    newline: bool,
    name: [*:0]const u8,
    dflt_file: ?*FILE,
) raise.Raising(repr.Value) {
    const x = vm_state.dyn(name);
    return printImplX(argv, newline, dflt_file, 0, x);
}

/// `print`, `prin`, `eprint` and `eprin` differ only in the dynamic binding
/// they read and whether they end with a newline.
fn Print(comptime newline: bool, comptime name: [:0]const u8, comptime handle: anytype) type {
    return struct {
        fn cfun(argv: []repr.Value) align(corefn.alignment) raise.Raising(repr.Value) {
            return print(argv, newline, name.ptr, handle());
        }
    };
}

/// `xprint` and `xprin` take the destination as their first argument instead,
/// and have no default handle to fall back on.
fn XPrint(comptime newline: bool) type {
    return struct {
        fn cfun(argv: []repr.Value) align(corefn.alignment) raise.Raising(repr.Value) {
            try args_core.arity(argv, 1, -1);
            return printImplX(argv, newline, null, 1, argv[0]);
        }
    };
}

fn printfImplX(
    argv: []repr.Value,
    newline: bool,
    dflt_file: ?*FILE,
    offset: usize,
    x: repr.Value,
) raise.Raising(repr.Value) {
    var f: ?*FILE = null;
    const fmt = try args_core.getCString(argv, offset);
    switch (repr.typeOf(x)) {
        repr.Tag.buffer => {
            // Special case buffer
            const buf = wrap.toBuffer(x);
            try pp_format.bufferFormat(buf, fmt, offset + 1, argv);
            if (newline) try buffers.pushU8(buf, '\n');
            return wrap.fromNil();
        },
        repr.Tag.function => {
            // Special case function
            const fun = wrap.toFunction(x);
            const buf = buffers.new(0);
            try pp_format.bufferFormat(buf, fmt, offset + 1, argv);
            if (newline) try buffers.pushU8(buf, '\n');
            var args = [_]repr.Value{wrap.fromBuffer(buf)};
            _ = try vm_entry.call(fun, (&args)[0..1]);
            return wrap.fromNil();
        },
        repr.Tag.nil => {
            f = dflt_file;
            if (f == null) return raise.panic("cannot print to nil");
        },
        repr.Tag.abstract => {
            const abstract = wrap.toAbstract(x);
            if (abi.abstractHead(abstract).type != &fileType) return wrap.fromNil();
            const iofile: *File = @ptrCast(@alignCast(abstract));
            // A closed file is reported differently here than by
            // `assertWriteable`, which would say "file is closed"; the C
            // original tests it separately and this reproduces that.
            if (iofile.flags & file_closed != 0) return raise.panic("cannot print to closed file");
            try assertWriteable(iofile);
            f = streamOf(iofile);
        },
        else => return pp_format.panicf("cannot print to %v", .{x}),
    }
    // Not a `defer`: a conversion that raises inside `janet_buffer_format`
    // jumps past the release below, exactly as it did in C. See the seam note
    // at the head of this file.
    const buf = buffers.new(10);
    try pp_format.bufferFormat(buf, fmt, offset + 1, argv);
    if (newline) try buffers.pushU8(buf, '\n');
    if (buf.count != 0) {
        if (write(f, buf.data.?, @intCast(buf.count)) != 1) {
            return pp_format.panicf("could not print %d bytes to file", .{@as(i64, @intCast(buf.count))});
        }
    }
    // Clear buffer to make things easier for GC
    buf.count = 0;
    buf.capacity = 0;
    utils.free(buf.data);
    buf.data = null;
    return wrap.fromNil();
}

fn printf(
    argv: []repr.Value,
    newline: bool,
    name: [*:0]const u8,
    dflt_file: ?*FILE,
) raise.Raising(repr.Value) {
    try args_core.arity(argv, 1, -1);
    const x = vm_state.dyn(name);
    return printfImplX(argv, newline, dflt_file, 0, x);
}

fn Printf(comptime newline: bool, comptime name: [:0]const u8, comptime handle: anytype) type {
    return struct {
        fn cfun(argv: []repr.Value) align(corefn.alignment) raise.Raising(repr.Value) {
            return printf(argv, newline, name.ptr, handle());
        }
    };
}

fn XPrintf(comptime newline: bool) type {
    return struct {
        fn cfun(argv: []repr.Value) align(corefn.alignment) raise.Raising(repr.Value) {
            try args_core.arity(argv, 2, -1);
            return printfImplX(argv, newline, null, 1, argv[0]);
        }
    };
}

/// Flush a dynamic binding if it names a file, and do nothing at all if it
/// names anything else. Neither `flush` nor `eflush` can fail.
fn flusher(name: [*:0]const u8, dflt_file: ?*FILE) void {
    const x = vm_state.dyn(name);
    switch (repr.typeOf(x)) {
        repr.Tag.nil => _ = flush(dflt_file),
        repr.Tag.abstract => {
            const abstract = wrap.toAbstract(x);
            if (abi.abstractHead(abstract).type != &fileType) return;
            const iofile: *File = @ptrCast(@alignCast(abstract));
            _ = flush(streamOf(iofile));
        },
        else => {},
    }
}

fn Flush(comptime name: [:0]const u8, comptime handle: anytype) type {
    return struct {
        fn cfun(argv: []repr.Value) align(corefn.alignment) raise.Raising(repr.Value) {
            try args_core.fixarity(argv, 0);

            flusher(name.ptr, handle());
            return wrap.fromNil();
        }
    };
}

// ==========================================================================
// The public C API
// ==========================================================================

pub fn getjfile(argv: []const repr.Value, n: usize) raise.Raising(*File) {
    return try args_core.getAbstract(File, argv, n, &fileType);
}

pub fn getfile(argv: []const repr.Value, n: usize, flags: ?*i32) raise.Raising(?*FILE) {
    const iof: *File = try args_core.getAbstract(File, argv, n, &fileType);
    if (flags) |slot| slot.* = iof.flags;
    return @ptrCast(iof.file);
}

pub fn makejfile(f: ?*FILE, flags: i32) *File {
    return makef(f, flags, bufsiz);
}

pub fn makefile(f: ?*FILE, flags: i32) repr.Value {
    return wrap.fromAbstract(makef(f, flags, bufsiz));
}

pub fn checkfile(j: repr.Value) abstracts.Abstract {
    return args_core.checkabstract(j, &fileType);
}

pub fn unwrapfile(j: repr.Value, flags: ?*i32) ?*FILE {
    const iof: *File = @ptrCast(@alignCast(wrap.toAbstract(j)));
    if (flags) |slot| slot.* = iof.flags;
    return @ptrCast(iof.file);
}

// ==========================================================================
// Registration
// ==========================================================================

pub fn libIo(env: *tables.Table) raise.Raising(void) {
    const entries = comptime [_]corefn.Entry{
        corefn.reg("print", &Print(true, "out", stdoutFile).cfun, @src(), "(print & xs)", "Print values to the console (standard out). Value are converted " ++
            "to strings if they are not already. After printing all values, a " ++
            "newline character is printed. Use the value of `(dyn :out stdout)` to determine " ++
            "what to push characters to. Expects `(dyn :out stdout)` to be either a core/file or " ++
            "a buffer. Returns nil."),
        corefn.reg("prin", &Print(false, "out", stdoutFile).cfun, @src(), "(prin & xs)", "Same as `print`, but does not add trailing newline."),
        corefn.reg("printf", &Printf(true, "out", stdoutFile).cfun, @src(), "(printf fmt & xs)", "Prints output formatted as if with `(string/format fmt ;xs)` to `(dyn :out stdout)` with a trailing newline."),
        corefn.reg("prinf", &Printf(false, "out", stdoutFile).cfun, @src(), "(prinf fmt & xs)", "Like `printf` but with no trailing newline."),
        corefn.reg("eprin", &Print(false, "err", stderrFile).cfun, @src(), "(eprin & xs)", "Same as `prin`, but uses `(dyn :err stderr)` instead of `(dyn :out stdout)`."),
        corefn.reg("eprint", &Print(true, "err", stderrFile).cfun, @src(), "(eprint & xs)", "Same as `print`, but uses `(dyn :err stderr)` instead of `(dyn :out stdout)`."),
        corefn.reg("eprintf", &Printf(true, "err", stderrFile).cfun, @src(), "(eprintf fmt & xs)", "Prints output formatted as if with `(string/format fmt ;xs)` to `(dyn :err stderr)` with a trailing newline."),
        corefn.reg("eprinf", &Printf(false, "err", stderrFile).cfun, @src(), "(eprinf fmt & xs)", "Like `eprintf` but with no trailing newline."),
        corefn.reg("xprint", &XPrint(true).cfun, @src(), "(xprint to & xs)", "Print to a file or other value explicitly (no dynamic bindings) with a trailing " ++
            "newline character. The value to print " ++
            "to is the first argument, and is otherwise the same as `print`. Returns nil."),
        corefn.reg("xprin", &XPrint(false).cfun, @src(), "(xprin to & xs)", "Print to a file or other value explicitly (no dynamic bindings). The value to print " ++
            "to is the first argument, and is otherwise the same as `prin`. Returns nil."),
        corefn.reg("xprintf", &XPrintf(true).cfun, @src(), "(xprintf to fmt & xs)", "Like `printf` but prints to an explicit file or value `to`. Returns nil."),
        corefn.reg("xprinf", &XPrintf(false).cfun, @src(), "(xprinf to fmt & xs)", "Like `prinf` but prints to an explicit file or value `to`. Returns nil."),
        corefn.reg("flush", &Flush("out", stdoutFile).cfun, @src(), "(flush)", "Flush `(dyn :out stdout)` if it is a file, otherwise do nothing."),
        corefn.reg("eflush", &Flush("err", stderrFile).cfun, @src(), "(eflush)", "Flush `(dyn :err stderr)` if it is a file, otherwise do nothing."),
        corefn.reg("file/temp", &cfunTemp, @src(), "(file/temp)", "Open an anonymous temporary file that is removed on close. " ++
            "Raises an error on failure."),
        corefn.reg("file/open", &cfunFopen, @src(), "(file/open path &opt mode buffer-size)", "Open a file. `path` is an absolute or relative path, and " ++
            "`mode` is a set of flags indicating the mode to open the file in. " ++
            "`mode` is a keyword where each character represents a flag. If the file " ++
            "cannot be opened, returns nil, otherwise returns the new file handle. " ++
            "Mode flags:\n\n" ++
            "* r - allow reading from the file\n\n" ++
            "* w - allow writing to the file\n\n" ++
            "* a - append to the file\n\n" ++
            "Following one of the initial flags, 0 or more of the following flags can be appended:\n\n" ++
            "* b - open the file in binary mode (rather than text mode)\n\n" ++
            "* + - append to the file instead of overwriting it\n\n" ++
            "* n - error if the file cannot be opened instead of returning nil\n\n" ++
            "See fopen (<stdio.h>, C99) for further details."),
        corefn.reg("file/close", &cfunFclose, @src(), "(file/close f)", "Close a file and release all related resources. When you are " ++
            "done reading a file, close it to prevent a resource leak and let " ++
            "other processes read the file."),
        corefn.reg("file/read", &cfunFread, @src(), "(file/read f what &opt buf)", "Read a number of bytes from a file `f` into a buffer. A buffer `buf` can " ++
            "be provided as an optional third argument, otherwise a new buffer " ++
            "is created. `what` can either be an integer or a keyword. Returns the " ++
            "buffer with file contents. " ++
            "Values for `what`:\n\n" ++
            "* :all - read the whole file\n\n" ++
            "* :line - read up to and including the next newline character\n\n" ++
            "* n (integer) - read up to n bytes from the file"),
        corefn.reg("file/write", &cfunFwrite, @src(), "(file/write f & bytes)", "Writes to a file `f`. Each value of `bytes` must be a " ++
            "string, buffer, symbol, or keyword. Returns the file."),
        corefn.reg("file/flush", &cfunFflush, @src(), "(file/flush f)", "Flush any buffered bytes to the file system. In most files, writes are " ++
            "buffered for efficiency reasons. Returns the file handle."),
        corefn.reg("file/seek", &cfunFseek, @src(), "(file/seek f &opt whence n)", "Jump to a relative location in the file `f`. `whence` must be one of:\n\n" ++
            "* :cur - jump relative to the current file location\n\n" ++
            "* :set - jump relative to the beginning of the file\n\n" ++
            "* :end - jump relative to the end of the file\n\n" ++
            "By default, `whence` is :cur. Optionally a value `n` may be passed " ++
            "for the relative number of bytes to seek in the file. `n` may be a real " ++
            "number to handle large files of more than 4GB. Returns the file handle."),
        corefn.reg("file/tell", &cfunFtell, @src(), "(file/tell f)", "Get the current value of the file position for file `f`."),
    };
    corefn.install(env, entries);
    try registry.registerAbstractType(&fileType);
    const default_flags: i32 = file_not_closeable | file_serializable;
    corefn.def(env, "stdout", makefile(stdoutFile(), file_append | default_flags), @src(), "The standard output file.");
    corefn.def(env, "stderr", makefile(stderrFile(), file_append | default_flags), @src(), "The standard error file.");
    corefn.def(env, "stdin", makefile(stdinFile(), file_read | default_flags), @src(), "The standard input file.");
}

fn scan(mode: []const u8) struct { status: i32, flags: i32, sandbox: vm_lifecycle.Sandbox, index: i32 } {
    var flags: i32 = 0;
    var sandbox_flags: vm_lifecycle.Sandbox = .{};
    var index: i32 = 0;
    const status = scanMode(mode.ptr, @intCast(mode.len), &flags, &sandbox_flags, &index);
    return .{ .status = status, .flags = flags, .sandbox = sandbox_flags, .index = index };
}

test "mode scanning accepts the documented flags" {
    const r = scan("r");
    try std.testing.expectEqual(mode_ok, r.status);
    try std.testing.expectEqual(file_read, r.flags);
    try std.testing.expectEqual(vm_lifecycle.Sandbox.of(&.{"fs_read"}), r.sandbox);

    const wbn = scan("wbn");
    try std.testing.expectEqual(mode_ok, wbn.status);
    try std.testing.expectEqual(file_write | file_binary | file_nonil, wbn.flags);
    try std.testing.expectEqual(vm_lifecycle.Sandbox.of(&.{"fs_write"}), wbn.sandbox);

    const ap = scan("a+");
    try std.testing.expectEqual(mode_ok, ap.status);
    try std.testing.expectEqual(file_append | file_update, ap.flags);
    try std.testing.expectEqual(vm_lifecycle.Sandbox.fs, ap.sandbox);
}

test "mode scanning reports where it stopped" {
    try std.testing.expectEqual(mode_bad_length, scan("").status);
    try std.testing.expectEqual(mode_bad_length, scan("rbbbbbbbbbb").status);
    try std.testing.expectEqual(mode_bad_first, scan("q").status);
    try std.testing.expectEqual(@as(i32, 0), scan("q").index);

    const later = scan("r+q");
    try std.testing.expectEqual(mode_bad_later, later.status);
    try std.testing.expectEqual(@as(i32, 2), later.index);
    try std.testing.expectEqual(vm_lifecycle.Sandbox.of(&.{ "fs_read", "fs_write" }), later.sandbox);
}

test "a repeated flag yields the flag word the C implementation returned" {
    for ([_][]const u8{ "r++", "rbb", "rnn" }) |mode| {
        const result = scan(mode);
        try std.testing.expectEqual(mode_repeated, result.status);
        try std.testing.expectEqual(@as(i32, -1), result.flags);
    }
    // The prefix before the repeat still reports its permissions, because the
    // C loop asserted them before reaching the repeated byte.
    try std.testing.expectEqual(vm_lifecycle.Sandbox.of(&.{ "fs_read", "fs_write" }), scan("r++").sandbox);
    try std.testing.expectEqual(vm_lifecycle.Sandbox.of(&.{"fs_read"}), scan("rbb").sandbox);
}

test "seek origins match whole keywords only" {
    try std.testing.expectEqual(@as(i32, 0), seekWhence("cur", 3));
    try std.testing.expectEqual(@as(i32, 1), seekWhence("set", 3));
    try std.testing.expectEqual(@as(i32, 2), seekWhence("end", 3));
    try std.testing.expectEqual(@as(i32, -1), seekWhence("cu", 2));
    try std.testing.expectEqual(@as(i32, -1), seekWhence("current", 7));
    try std.testing.expectEqual(@as(i32, -1), seekWhence("", 0));
}

test "mode reconstruction collapses append over write" {
    var out: [4]u8 = undefined;
    try std.testing.expectEqual(@as(i32, 2), modeFromFlags(file_read | file_write, &out));
    try std.testing.expectEqualStrings("rw", out[0..2]);
    try std.testing.expectEqual(@as(u8, 0), out[2]);

    try std.testing.expectEqual(@as(i32, 2), modeFromFlags(file_read | file_write | file_append, &out));
    try std.testing.expectEqualStrings("ra", out[0..2]);

    try std.testing.expectEqual(@as(i32, 1), modeFromFlags(file_append | file_binary, &out));
    try std.testing.expectEqualStrings("a", out[0..1]);

    try std.testing.expectEqual(@as(i32, 0), modeFromFlags(file_binary, &out));
    try std.testing.expectEqual(@as(u8, 0), out[0]);
}

pub const File = struct {
    file: ?*host.FILE = null,
    flags: i32 = 0,
    vbufsize: usize = 0,
};
