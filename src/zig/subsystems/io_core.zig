//! Files: `src/core/io.c` entire, less a variadic and a directory test that
//! neither could move. The `core/file` abstract type and its five callbacks,
//! the twenty-two cfunctions of the `file/` and `print`/`printf` families, the
//! eight public `JanetFile` entry points, the mode-string kernels, the stream
//! host operations, and the registration. This is Phase 10 Part 11.
//!
//! ## No new selector
//!
//! `-Dio-core` already owned this subject. Part 5's rule -- a selector's
//! subject is a subsystem, not a file -- and Part 6's application of it are
//! what decide this: the surface goes to the selector that already holds the
//! kernel it sits on, and the count stays at fifty-eight. The name keeps the
//! `core` suffix four other selectors carry for "a kernel whose cfunction
//! surface is still in C", which stops being true here; renaming it would move
//! every matrix entry and every acceptance table for nothing.
//!
//! ## What is left in C, and why it cannot move
//!
//! `janet_dynprintf` is a C variadic and public API, so its signature is the
//! contract. Part 4's rule binds: Zig can *call* a C variadic but cannot
//! define one. It stays in `io.c` with the three `janet_zig_std*` handles it
//! needs -- `stderr`, `stdout` and `stdin` are macros that translate-c renders
//! three incompatible ways across this project's targets -- and all four go
//! with `janet_panicf` in Part 17. The one thing that body cannot do for
//! itself is the writeability check, because that raises; it calls
//! `janet_zig_io_assert_writeable` below.
//!
//! ## The raise shape, and why the marker is here
//!
//! Every `janet_panic` in the original is an error return: a cfunction that
//! decides to raise is an `Impl` returning `raise.Raising(Janet)` behind a
//! two-line C face, and one that makes no such decision stays the plain
//! `JanetCFunction` it is. Twenty of the twenty-two raise; the two that cannot
//! are `flush` and `eflush`, whose three arms are "flush it", "flush the
//! default handle" and "do nothing". That is Part 10's finding applied rather
//! than restated.
//!
//! The file is nonetheless jump-transparent, and gains the marker in this
//! increment. It made no raise-capable call at all before: the kernels are
//! pure and the host operations report failure by returning. The surface
//! calls `janet_arity`, `janet_getabstract` and nine of their relatives, which
//! are `-Dargs-core`'s C faces; `janet_buffer_format`, which is `-Dpp`'s; and
//! `janet_sandbox_assert`, which is `-Dvm-lifecycle`'s. Each crosses the C ABI
//! and therefore raises by jumping. Part 4's seam rule is why that cannot be
//! avoided here.
//!
//! One consequence is visible in `printfImplX`: the C original builds a
//! scratch buffer, formats into it, and frees its backing store by hand. A
//! conversion that raises inside `janet_buffer_format` jumps past that free in
//! C and jumps past it here too, which is the reproduction rather than a
//! regression -- and is exactly the `defer` the marker forbids.
//!
//! ## `FILE`, and the two things translate-c will not give this file
//!
//! `FILE` is opaque by definition, so a stream crosses the kernel boundary as
//! a handle rather than as a structure; that is what separated this file from
//! `os_stat.zig` before the surface arrived. `translate-c` does not agree,
//! because it renders what the *platform header* says: macOS spells out
//! `struct __sFILE` and musl leaves `struct _IO_FILE` incomplete, so
//! `JanetFile.file` translates to a `[*c]` pointer on one and an optional
//! pointer on the other, and `[*c]c.FILE` does not compile on musl at all.
//! This file therefore declares its own `FILE` below and converts at the
//! field, in `streamOf` and `setStreamOf`. Every native matrix entry accepted
//! the translated spelling; three of the four cross-compiles did not.
//!
//! The other thing is `struct stat`. `file/open` rejects a directory by
//! `fstat`ing the descriptor it just opened, `std.c.fstat` is `{}` on Linux
//! and `std.c.Stat` has no Linux arm, and the two ways a Zig frame could get
//! one anyway are both refused elsewhere in this tree -- a second `@cImport`
//! over `<sys/stat.h>` is the duplicate translation `abi.zig`'s
//! single-translation rule prevents, and a hand-written layout per platform is
//! what `os_stat.zig` declined to do with `jstat_t`. So the test keeps a
//! five-line C body, `janet_zig_io_isdir`, and this file calls it.
//!
//! The marshalling path reaches a descriptor, through `dup` and `fdopen`.
//! Plan 9 spells `dup` with two arguments, and the C original has a branch for
//! it; there is no Zig target for Plan 9 in this project, so that branch is
//! recorded here and not written. A Plan 9 build selects `-Dio-core=c`.

const std = @import("std");
const builtin = @import("builtin");
const abi = @import("abi");
const corefn = @import("corefn");
const raise = @import("raise");
const registration = @import("registration.zig");
const c = abi.c;
const stdio = @import("stdio.zig");
const printer = @import("printer.zig");
const marshalling = @import("marshalling.zig");
const lifecycle = @import("lifecycle.zig");
const containers = @import("containers.zig");
const arglayer = @import("arglayer.zig");
const marsh = @import("marsh.zig");
const pp_format = @import("pp_format.zig");
const vm_entry = @import("vm_entry.zig");
const abstract_type = @import("abstract_type.zig");

const windows = builtin.os.tag == .windows;

/// Mirrors the `JANET_FILE_*` flags in `src/include/janet.h`.
const file_write: i32 = 1;
const file_read: i32 = 2;
const file_append: i32 = 4;
const file_update: i32 = 8;
const file_binary: i32 = 64;
const file_nonil: i32 = 512;

/// Mirrors the `JANET_SANDBOX_FS*` flags in `src/include/janet.h`. This
/// subsystem reports which of them a mode string implies; C performs the
/// assertion, because a forbidden operation panics.
const sandbox_fs_write: u32 = 32;
const sandbox_fs_read: u32 = 64;
const sandbox_fs_temp: u32 = 1024;
const sandbox_fs: u32 = sandbox_fs_write | sandbox_fs_read | sandbox_fs_temp;

/// Mirrors the `JANET_IO_MODE_*` codes in `src/core/io.c`.
const mode_ok: i32 = 0;
const mode_bad_length: i32 = 1;
const mode_bad_first: i32 = 2;
const mode_bad_later: i32 = 3;
const mode_repeated: i32 = 4;

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

pub const FILE = opaque {};

extern fn fopen(path: [*:0]const u8, mode: [*:0]const u8) callconv(.c) ?*FILE;
extern fn tmpfile() callconv(.c) ?*FILE;
extern fn fclose(file: ?*FILE) callconv(.c) c_int;
extern fn fflush(file: ?*FILE) callconv(.c) c_int;
extern fn fread(dest: [*]u8, size: usize, count: usize, file: ?*FILE) callconv(.c) usize;
extern fn fwrite(src: [*]const u8, size: usize, count: usize, file: ?*FILE) callconv(.c) usize;
extern fn fgetc(file: ?*FILE) callconv(.c) c_int;
extern fn fputc(ch: c_int, file: ?*FILE) callconv(.c) c_int;
extern fn ferror(file: ?*FILE) callconv(.c) c_int;
extern fn setvbuf(file: ?*FILE, buffer: ?[*]u8, mode: c_int, size: usize) callconv(.c) c_int;
extern fn fileno(file: ?*FILE) callconv(.c) c_int;

extern fn fseek(file: ?*FILE, offset: c_long, whence: c_int) callconv(.c) c_int;
extern fn ftell(file: ?*FILE) callconv(.c) c_long;

/// Janet redirects `fseek` and `ftell` to the 64-bit Microsoft variants, so the
/// port calls what the C implementation calls rather than the narrow ones.
extern fn _fseeki64(file: ?*FILE, offset: i64, whence: c_int) callconv(.c) c_int;
extern fn _ftelli64(file: ?*FILE) callconv(.c) i64;

comptime {
    @export(&scanMode, .{ .name = "janet_io_scan_mode" });
    @export(&seekWhence, .{ .name = "janet_io_seek_whence" });
    @export(&modeFromFlags, .{ .name = "janet_io_mode_from_flags" });
    @export(&open, .{ .name = "janet_io_open" });
    @export(&temp, .{ .name = "janet_io_temp" });
    @export(&close, .{ .name = "janet_io_close" });
    @export(&flush, .{ .name = "janet_io_flush" });
    @export(&read, .{ .name = "janet_io_read" });
    @export(&write, .{ .name = "janet_io_write" });
    @export(&getChar, .{ .name = "janet_io_getc" });
    @export(&putChar, .{ .name = "janet_io_putc" });
    @export(&err, .{ .name = "janet_io_error" });
    @export(&setBufferSize, .{ .name = "janet_io_setvbuf" });
    @export(&seek, .{ .name = "janet_io_seek" });
    @export(&tell, .{ .name = "janet_io_tell" });
    if (!windows) {
        @export(&setCloexec, .{ .name = "janet_io_set_cloexec" });
    }
}

/// Classify an `file/open` mode string.
///
/// Reports the flag word, the sandbox permissions the accepted prefix implies,
/// and where the scan stopped. C asserts the permissions and raises the errors,
/// so ordering matters: the permissions accumulate only over the bytes the C
/// loop would have reached before stopping, which is what lets C assert them
/// before reporting a later bad byte and reproduce the original interleaving.
///
/// A repeated flag yields a flag word of -1, which is what the C implementation
/// returned and what its caller then used as a flag word. That is recorded in
/// `FOUND.md` as a defect and reproduced rather than fixed.
fn scanMode(
    mode: [*]const u8,
    len: i32,
    flags_out: *i32,
    sandbox_out: *u32,
    index_out: *i32,
) callconv(.c) i32 {
    flags_out.* = 0;
    sandbox_out.* = 0;
    index_out.* = 0;
    if (len < 1 or len > 10) return mode_bad_length;

    var flags: i32 = 0;
    switch (mode[0]) {
        'w' => {
            flags |= file_write;
            sandbox_out.* |= sandbox_fs_write;
        },
        'a' => {
            flags |= file_append;
            sandbox_out.* |= sandbox_fs;
        },
        'r' => {
            flags |= file_read;
            sandbox_out.* |= sandbox_fs_read;
        },
        else => return mode_bad_first,
    }

    var index: i32 = 1;
    while (index < len) : (index += 1) {
        index_out.* = index;
        switch (mode[@intCast(index)]) {
            '+' => {
                if (flags & file_update != 0) return repeated(flags_out);
                sandbox_out.* |= sandbox_fs_write;
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
fn seekWhence(key: [*]const u8, len: i32) callconv(.c) i32 {
    if (len < 0) return -1;
    for (whence_names, 0..) |name, index| {
        if (cstrequal(key, @intCast(len), name)) return @intCast(index);
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

/// Rebuild the `fopen` mode a flag word came from, for reattaching a marshalled
/// descriptor. Writes at most three bytes plus a terminator into `out` and
/// returns the length.
///
/// This is not the inverse of `scanMode`: it drops the binary, update, and
/// no-nil flags, and it collapses append and write, because the C
/// implementation only needed a mode `fdopen` would accept.
fn modeFromFlags(flags: i32, out: *[4]u8) callconv(.c) i32 {
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

fn open(path: [*:0]const u8, mode: [*:0]const u8) callconv(.c) ?*anyopaque {
    return @ptrCast(fopen(path, mode));
}

fn temp() callconv(.c) ?*anyopaque {
    return @ptrCast(tmpfile());
}

/// Each host operation is written once over a stream and exported once over a
/// handle. The seam carries a `void *` because a `FILE` is opaque by
/// definition, and every caller inside this file has a `JanetFile` and
/// therefore a stream already.
///
/// The stream is optional throughout. A closed `JanetFile` holds a null, and
/// two of the paths below can be reached with one: `fflush(NULL)` flushes
/// every output stream in the process, and `setvbuf(NULL, ...)` is undefined.
/// Both are recorded in `FOUND.md` and reproduced rather than trapped on,
/// which is only possible if the null travels as a null instead of through a
/// checked cast.
fn closeStream(file: ?*FILE) i32 {
    return fclose(file);
}

fn close(handle: *anyopaque) callconv(.c) i32 {
    return closeStream(stream(handle));
}

fn flushStream(file: ?*FILE) i32 {
    return fflush(file);
}

fn flush(handle: *anyopaque) callconv(.c) i32 {
    return flushStream(stream(handle));
}

/// Read up to `count` bytes, reporting how many arrived. A short read is not by
/// itself a failure, which is why a caller consults `err` afterwards.
fn readStream(file: ?*FILE, dest: [*]u8, count: usize) usize {
    return fread(dest, 1, count, file);
}

fn read(handle: *anyopaque, dest: [*]u8, count: usize) callconv(.c) usize {
    return readStream(stream(handle), dest, count);
}

/// Write `count` bytes as a single item, so the result is 1 on success and 0 on
/// failure. Callers compare against 1, as the C original did with `fwrite`
/// directly.
/// The three standard streams as this file's `FILE`.
///
/// `stdio.zig` hands back `?*anyopaque`, because the macro it replaces expands
/// to a different spelling on every platform and none of them is a type this
/// file wants to name. One cast, in one place, rather than at each of the
/// dozen registration rows below.
fn stdinFile() ?*FILE {
    return @ptrCast(@alignCast(stdio.in()));
}
fn stdoutFile() ?*FILE {
    return @ptrCast(@alignCast(stdio.out()));
}
fn stderrFile() ?*FILE {
    return @ptrCast(@alignCast(stdio.err()));
}

fn writeStream(file: ?*FILE, src: [*]const u8, count: usize) i32 {
    return @intCast(fwrite(src, count, 1, file));
}

fn write(handle: *anyopaque, src: [*]const u8, count: usize) callconv(.c) i32 {
    return writeStream(stream(handle), src, count);
}

/// Read one byte, or return `EOF`.
fn getCharStream(file: ?*FILE) i32 {
    return fgetc(file);
}

fn getChar(handle: *anyopaque) callconv(.c) i32 {
    return getCharStream(stream(handle));
}

fn putCharStream(file: ?*FILE, ch: i32) i32 {
    return fputc(ch, file);
}

fn putChar(handle: *anyopaque, ch: i32) callconv(.c) i32 {
    return putCharStream(stream(handle), ch);
}

fn errStream(file: ?*FILE) i32 {
    return ferror(file);
}

fn err(handle: *anyopaque) callconv(.c) i32 {
    return errStream(stream(handle));
}

/// Select full buffering of `size` bytes, or no buffering when `size` is zero.
fn setBufferSizeStream(file: ?*FILE, size: usize) i32 {
    return setvbuf(file, null, if (size != 0) iofbf else ionbf, size);
}

fn setBufferSize(handle: *anyopaque, size: usize) callconv(.c) i32 {
    return setBufferSizeStream(stream(handle), size);
}

/// Move the file position, with `whence` given as a position in
/// `whence_names`. An unrecognized origin cannot reach here: a caller rejects
/// it while it still holds the keyword to name in the panic.
fn seekStream(file: ?*FILE, offset: i64, whence: i32) i32 {
    const origin: c_int = switch (whence) {
        0 => seek_cur,
        1 => seek_set,
        else => seek_end,
    };
    if (windows) return _fseeki64(file, offset, origin);
    // A 32-bit `long` narrows the offset here exactly as the C
    // implementation's implicit conversion did; `FOUND.md` records what that
    // costs a 32-bit host.
    return fseek(file, @truncate(offset), origin);
}

fn seek(handle: *anyopaque, offset: i64, whence: i32) callconv(.c) i32 {
    return seekStream(stream(handle), offset, whence);
}

fn tellStream(file: ?*FILE) i64 {
    if (windows) return _ftelli64(file);
    return ftell(file);
}

fn tell(handle: *anyopaque) callconv(.c) i64 {
    return tellStream(stream(handle));
}

/// Close the stream's descriptor across an exec. `fopen` has no standard flag
/// for this, which is why the C implementation set it separately.
fn setCloexecStream(file: ?*FILE) i32 {
    return std.c.fcntl(fileno(file), std.c.F.SETFD, fd_cloexec);
}

fn setCloexec(handle: *anyopaque) callconv(.c) i32 {
    return setCloexecStream(stream(handle));
}

fn stream(handle: *anyopaque) *FILE {
    return @ptrCast(handle);
}

// ==========================================================================
// The `core/file` abstract type
// ==========================================================================

/// Mirrors the remaining `JANET_FILE_*` flags in `src/include/janet.h`. The
/// four the mode scanner produces are above.
const file_not_closeable: i32 = 16;
const file_closed: i32 = 32;
const file_serializable: i32 = 128;

/// Whether this is a Plan 9 build. `dup` takes a second argument there and
/// `fopen` needs no close-on-exec fixup; both branches are unreachable from
/// Zig, because Plan 9 is not one of this project's targets, and are recorded
/// rather than written. `math.zig` reads its own gate the same way.
const plan9 = @hasDecl(c, "JANET_PLAN9");

/// The C library's default buffer size, which `file/open` compares against to
/// decide whether the caller asked for a different one.
const bufsiz: usize = c.BUFSIZ;

const eof: i32 = c.EOF;

extern fn dup(fd: c_int) callconv(.c) c_int;
extern fn _fileno(file: ?*FILE) callconv(.c) c_int;
extern fn fdopen(fd: c_int, mode: [*:0]const u8) callconv(.c) ?*FILE;
extern fn _dup(fd: c_int) callconv(.c) c_int;
extern fn _fdopen(fd: c_int, mode: [*:0]const u8) callconv(.c) ?*FILE;

/// `src/core/util.h`, which `abi.zig` deliberately does not translate.
///
/// `janet_buffer_format` is `-Dpp`'s C face, so a bad conversion inside it
/// raises by jumping through the frames below; see the seam note at the head
/// of this file.
extern fn janet_strerror(e: c_int) callconv(.c) [*c]const u8;
extern fn janet_buffer_format(
    b: *c.JanetBuffer,
    strfrmt: [*c]const u8,
    argstart: i32,
    argc: i32,
    argv: [*c]c.Janet,
) callconv(.c) void;

/// `src/core/io.c`. The three handles that cannot be named from Zig; the note
/// beside them there has the three spellings translate-c produces.
/// `src/core/io.c` again: the directory test, which needs `struct stat`.
extern fn janet_zig_io_isdir(file: *anyopaque) callconv(.c) c_int;


inline fn errno() c_int {
    return std.c._errno().*;
}

/// The stream a `JanetFile` holds.
///
/// The `@ptrCast` is not cosmetic. `translate-c` renders `FILE` as a complete
/// structure where the platform header defines one and as an opaque type where
/// it does not -- musl is the second case -- so `JanetFile.file` is a `[*c]`
/// C pointer on macOS and an optional pointer on musl, and no single spelling
/// of that type compiles on both. This file names its own `FILE` instead, and
/// converts at the field. The cross-compile matrix entries are what found
/// that; nothing on the host does.
inline fn streamOf(iof: *c.JanetFile) ?*FILE {
    return @ptrCast(iof.file);
}

/// Store a stream into a `JanetFile`, the inverse of `streamOf` and needing
/// the same conversion. The `@alignCast` is what the complete-structure
/// spelling asks for and what the opaque one ignores.
inline fn setStreamOf(iof: *c.JanetFile, file: ?*FILE) void {
    iof.file = @ptrCast(@alignCast(file));
}

/// The one path that holds a stream as the seam's `void *`
/// rather than as a `JanetFile`: `file/open` has to `fstat` and possibly
/// `fclose` its result before there is a payload to put it in.
inline fn streamOfHandle(handle: *anyopaque) ?*FILE {
    return @ptrCast(handle);
}

fn getFile(argv: [*c]c.Janet, n: i32) raise.Raising(*c.JanetFile) {
    return @ptrCast(@alignCast(try arglayer.getAbstract(argv, n, abstract_type.stored(&janet_file_type))));
}

/// `JANET_EXIT`, which `janet_assert` expands to and which `abi.zig` does not
/// translate.
///
/// Two things here are not the C original's. The location reported is this
/// file's rather than `io.c`'s, and an embedder's own `JANET_EXIT` is a
/// preprocessor override that no Zig caller can see; `src/zig/README.md`
/// records both. The message is assembled at compile time and written with
/// `fwrite` rather than handed to `fprintf`, because `fprintf` takes the
/// *translated* `FILE *` and this file deliberately does not name that type.
fn exitWith(comptime where: std.builtin.SourceLocation, comptime message: []const u8) noreturn {
    const line = std.fmt.comptimePrint(
        "janet abort at {s}:{d}: {s}\n",
        .{ where.file, where.line, message },
    );
    _ = writeStream(stderrFile(), line.ptr, line.len);
    c.abort();
}

fn fileGC(pointer: ?*anyopaque, len: usize) callconv(.c) c_int {
    _ = len;
    const iof: *c.JanetFile = @ptrCast(@alignCast(pointer));
    _ = closeFile(iof);
    return 0;
}

fn fileGet(pointer: ?*anyopaque, key: c.Janet, out: [*c]c.Janet) raise.Raising(c_int) {
    _ = pointer;
    if (c.janet_checktype(key, c.JANET_KEYWORD) == 0) return 0;
    return c.janet_getmethod(c.janet_unwrap_keyword(key), @ptrCast(&file_methods), out);
}

fn fileNext(pointer: ?*anyopaque, key: c.Janet) raise.Raising(c.Janet) {
    _ = pointer;
    return c.janet_nextmethod(@ptrCast(&file_methods), key);
}

/// Write a live descriptor into the stream, which only an unsafe marshal may
/// do. A closeable file is duplicated so that the marshalled copy owns its own
/// descriptor; a borrowed one -- `stdout` and its kin -- is written as it
/// stands.
fn fileMarshal(pointer: ?*anyopaque, ctx: [*c]c.JanetMarshalContext) raise.Raising(void) {
    const iof: *c.JanetFile = @ptrCast(@alignCast(pointer));
    if (c.janet_marshal_flags(ctx) & c.JANET_MARSHAL_UNSAFE == 0) {
        return raise.panic("cannot marshal file in safe mode");
    }
    c.janet_marshal_abstract(ctx, pointer);
    const borrowed = iof.flags & file_not_closeable != 0;
    const fno: c_int = if (windows)
        (if (borrowed) _fileno(streamOf(iof)) else _dup(_fileno(streamOf(iof))))
    else
        (if (borrowed) fileno(streamOf(iof)) else dup(fileno(streamOf(iof))));
    try marshalling.marshalInt(ctx, @intCast(fno));
    try marshalling.marshalInt(ctx, iof.flags);
    c.janet_marshal_size(ctx, iof.vbufsize);
}

/// Reattach a descriptor read back out of a stream.
///
/// The mode is rebuilt from the flag word rather than carried, which is why
/// `modeFromFlags` is not the inverse of `scanMode`: `fdopen` only has to
/// accept it.
fn fileUnmarshal(ctx: [*c]c.JanetMarshalContext) raise.Raising(?*anyopaque) {
    if (c.janet_unmarshal_flags(ctx) & c.JANET_MARSHAL_UNSAFE == 0) {
        return raise.panic("cannot unmarshal file in safe mode");
    }
    const iof: *c.JanetFile = @ptrCast(@alignCast(try marsh.unmarshalAbstract(ctx, @sizeOf(c.JanetFile))));
    const fd = try marsh.unmarshalInt(ctx);
    const flags = try marsh.unmarshalInt(ctx);
    var fmt: [4]u8 = undefined;
    _ = modeFromFlags(flags, &fmt);
    const reopened = if (windows) _fdopen(fd, @ptrCast(&fmt)) else fdopen(fd, @ptrCast(&fmt));
    setStreamOf(iof, reopened);
    iof.flags = if (reopened == null) file_closed else flags;
    iof.vbufsize = try marsh.unmarshalSize(ctx);
    if (iof.vbufsize != bufsiz) {
        if (setBufferSizeStream(reopened, iof.vbufsize) != 0) {
            exitWith(@src(), "unmarshal setvbuf");
        }
    }
    return iof;
}

export const janet_file_type: abstract_type.AbstractType = .{
    .name = "core/file",
    .gc = fileGC,
    .gcmark = null,
    .get = fileGet,
    .put = null,
    .marshal = fileMarshal,
    .unmarshal = fileUnmarshal,
    .tostring = null,
    .compare = null,
    .hash = null,
    .next = fileNext,
    .call = null,
    .length = null,
    .bytes = null,
    .gcperthread = null,
};

// ==========================================================================
// Opening, and the checks around it
// ==========================================================================

/// Scan an `file/open` mode string and raise what it reports.
///
/// The interleaving is the C original's and matters: the permissions the
/// accepted prefix implies are asserted *before* a later bad flag is reported,
/// so a sandboxed build refuses `:wq` for the sandbox rather than for the `q`.
fn checkFlags(str: c.JanetString) raise.Raising(i32) {
    var flags: i32 = 0;
    var sandbox_flags: u32 = 0;
    var index: i32 = 0;
    const status = scanMode(str, c.janet_string_length(str), &flags, &sandbox_flags, &index);
    if (status == mode_bad_length) {
        return raise.panic("file mode must have a length between 1 and 10");
    }
    if (status == mode_bad_first) {
        return pp_format.panicf("invalid flag %c, expected w, a, or r", .{@as(c_int, str[@intCast(index)])});
    }
    try lifecycle.sandboxAssert(sandbox_flags);
    if (status == mode_bad_later) {
        return pp_format.panicf("invalid flag %c, expected +, b, or n", .{@as(c_int, str[@intCast(index)])});
    }
    return flags;
}

/// Wrap a stream in the abstract that owns it.
///
/// `fopen` has no standard way to ask for close-on-exec -- the `e` mode flag
/// is a GNU extension -- so a file this runtime will close is marked
/// separately, and one it only borrows is left alone.
fn makef(f: ?*FILE, flags: i32, bufsize: usize) *c.JanetFile {
    const iof: *c.JanetFile = @ptrCast(@alignCast(c.janet_abstract(abstract_type.stored(&janet_file_type), @sizeOf(c.JanetFile))));
    setStreamOf(iof, f);
    iof.flags = flags;
    iof.vbufsize = bufsize;
    if (!windows and !plan9) {
        if (flags & file_not_closeable == 0) _ = setCloexecStream(f);
    }
    return iof;
}

fn cfunTemp(argc: i32, argv: [*c]c.Janet) align(corefn.alignment) raise.Raising(c.Janet) {
    try lifecycle.sandboxAssert(sandbox_fs_temp);
    _ = argv;
    try arglayer.fixarity(argc, 0);
    // XXX use mkostemp when we can to avoid CLOEXEC race.
    const tmp = temp() orelse {
        return pp_format.panicf("unable to create temporary file - %s", .{janet_strerror(errno())});
    };
    return janet_makefile(@ptrCast(tmp), file_write | file_read | file_binary);
}

fn cfunFopen(argc: i32, argv: [*c]c.Janet) align(corefn.alignment) raise.Raising(c.Janet) {
    try arglayer.arity(argc, 1, 3);
    const fname = try arglayer.getString(argv, 0);
    var fmode: c.JanetString = undefined;
    var flags: i32 = undefined;
    // A third argument leaves the mode unscanned and the file read-only; that
    // is the C original's `argc == 2` and is recorded in `FOUND.md`.
    if (argc == 2) {
        fmode = try arglayer.getKeyword(argv, 1);
        flags = try checkFlags(fmode);
    } else {
        fmode = @ptrCast("r");
        try lifecycle.sandboxAssert(sandbox_fs_read);
        flags = file_read;
    }
    const f = open(@ptrCast(fname), @ptrCast(fmode));
    var bufsize: usize = bufsiz;
    if (f) |handle| {
        // A directory that `fopen` accepted is rejected here. The test is
        // `io.c`'s, not this file's: see `janet_zig_io_isdir` there for why a
        // `struct stat` cannot be named from Zig on all four targets.
        if (janet_zig_io_isdir(handle) != 0) {
            _ = closeStream(streamOfHandle(handle));
            return pp_format.panicf("cannot open directory: %s", .{fname});
        }
        bufsize = try arglayer.optSize(argv, argc, 2, bufsiz);
        if (bufsize != bufsiz) {
            if (setBufferSizeStream(streamOfHandle(handle), bufsize) != 0) {
                return raise.panic("failed to set buffer size for file");
            }
        }
    }
    if (f) |handle| return c.janet_wrap_abstract(makef(@ptrCast(handle), flags, bufsize));
    if (flags & file_nonil != 0) {
        return pp_format.panicf("failed to open file %s: %s", .{ fname, janet_strerror(errno()) });
    }
    return c.janet_wrap_nil();
}

// ==========================================================================
// Reading, writing, and positioning
// ==========================================================================

/// Read up to `n_bytes_max` bytes onto the end of `buffer`.
///
/// A short read is not by itself a failure -- it is how the end of the file is
/// reached -- so the error indicator decides.
fn readChunk(iof: *c.JanetFile, buffer: *c.JanetBuffer, n_bytes_max: i32) raise.Raising(void) {
    if (iof.flags & (file_read | file_update) == 0) {
        return raise.panic("file is not readable");
    }
    try containers.bufferExtra(buffer, n_bytes_max);
    const ntoread: usize = @intCast(n_bytes_max);
    const nread = readStream(streamOf(iof), buffer.data + @as(usize, @intCast(buffer.count)), ntoread);
    if (nread != ntoread and errStream(streamOf(iof)) != 0) {
        return raise.panic("could not read file");
    }
    buffer.count += @intCast(nread);
}

fn cfunFread(argc: i32, argv: [*c]c.Janet) align(corefn.alignment) raise.Raising(c.Janet) {
    try arglayer.arity(argc, 2, 3);
    const iof = try getFile(argv, 0);
    if (iof.flags & file_closed != 0) return raise.panic("file is closed");
    const buffer = if (argc == 2) c.janet_buffer(0) else try arglayer.getBuffer(argv, 2);
    const bufstart = buffer.*.count;
    if (c.janet_checktype(argv[1], c.JANET_KEYWORD) != 0) {
        const sym = c.janet_unwrap_keyword(argv[1]);
        if (c.janet_cstrcmp(sym, "all") == 0) {
            var size_before: i32 = undefined;
            while (true) {
                size_before = buffer.*.count;
                try readChunk(iof, buffer, 4096);
                if (size_before >= buffer.*.count) break;
            }
            // Never return nil for :all
            return c.janet_wrap_buffer(buffer);
        } else if (c.janet_cstrcmp(sym, "line") == 0) {
            while (true) {
                const x = getCharStream(streamOf(iof));
                if (x != eof) try containers.bufferPushU8(buffer, @intCast(x));
                if (x == eof or x == '\n') break;
            }
        } else {
            return pp_format.panicf("expected one of :all, :line, got %v", .{argv[1]});
        }
    } else {
        const len = try arglayer.getInteger(argv, 1);
        if (len < 0) return raise.panic("expected positive integer");
        try readChunk(iof, buffer, len);
    }
    if (bufstart == buffer.*.count) return c.janet_wrap_nil();
    return c.janet_wrap_buffer(buffer);
}

fn cfunFwrite(argc: i32, argv: [*c]c.Janet) align(corefn.alignment) raise.Raising(c.Janet) {
    try arglayer.arity(argc, 1, -1);
    const iof = try getFile(argv, 0);
    if (iof.flags & file_closed != 0) return raise.panic("file is closed");
    if (iof.flags & (file_write | file_append | file_update) == 0) {
        return raise.panic("file is not writeable");
    }
    // Verify all arguments before writing to file
    var i: i32 = 1;
    while (i < argc) : (i += 1) _ = try arglayer.getBytes(argv, i);
    i = 1;
    while (i < argc) : (i += 1) {
        const view = try arglayer.getBytes(argv, i);
        if (view.len != 0) {
            if (writeStream(streamOf(iof), view.bytes, @intCast(view.len)) == 0) {
                return raise.panic("error writing to file");
            }
        }
    }
    return argv[0];
}

// `dynprintf` moved to `pp_format.zig` in Part 18. It is one of the four
// entry points the C variadic surface used to hold -- `janet_formatc`,
// `janet_formatb`, `janet_panicf` and this -- and the other three were always
// in `pp.c`. Its format string is `comptime`, so a caller instantiates it
// rather than calling it, and a *contract* for it has to be compiled beside
// the engine; keeping it here would have meant compiling all of `io_core.zig`
// into that contract's module. What it needs from this file is three symbols
// it takes through the C ABI: `janet_zig_io_assert_writeable`,
// `janet_io_write` and `janet_file_type`.

fn assertWriteable(iof: *c.JanetFile) raise.Raising(void) {
    if (iof.flags & file_closed != 0) return raise.panic("file is closed");
    if (iof.flags & (file_write | file_append | file_update) == 0) {
        return raise.panic("file is not writeable");
    }
}

/// The C face `janet_dynprintf` calls. It is the only reason this check has
/// one: every other caller is in this file. It goes with that variadic in
/// Part 17.
export fn janet_zig_io_assert_writeable(iof: *c.JanetFile) callconv(.c) void {
    raise.reported(assertWriteable(iof));
}

fn cfunFflush(argc: i32, argv: [*c]c.Janet) align(corefn.alignment) raise.Raising(c.Janet) {
    try arglayer.fixarity(argc, 1);
    const iof = try getFile(argv, 0);
    try assertWriteable(iof);
    if (flushStream(streamOf(iof)) != 0) return raise.panic("could not flush file");
    return argv[0];
}

/// Close a file from the C API, reporting the host's result.
///
/// A file that is already closed, or that this runtime only borrowed, reports
/// success and is left alone. The stream pointer is cleared on the way out:
/// the C original's comment says a null dereference is easier to debug than
/// the alternative.
fn closeFile(file: *c.JanetFile) c_int {
    if (file.flags & (file_not_closeable | file_closed) == 0) {
        const ret = closeStream(streamOf(file));
        file.flags |= file_closed;
        file.file = null;
        return ret;
    }
    return 0;
}

export fn janet_file_close(file: *c.JanetFile) callconv(.c) c_int {
    return closeFile(file);
}

fn cfunFclose(argc: i32, argv: [*c]c.Janet) align(corefn.alignment) raise.Raising(c.Janet) {
    try arglayer.fixarity(argc, 1);
    const iof = try getFile(argv, 0);
    if (iof.flags & file_closed != 0) return c.janet_wrap_nil();
    if (iof.flags & file_not_closeable != 0) return raise.panic("file not closable");
    if (closeStream(streamOf(iof)) != 0) {
        iof.flags |= file_not_closeable;
        return raise.panic("could not close file");
    }
    iof.flags |= file_closed;
    return c.janet_wrap_nil();
}

fn cfunFseek(argc: i32, argv: [*c]c.Janet) align(corefn.alignment) raise.Raising(c.Janet) {
    try arglayer.arity(argc, 2, 3);
    const iof = try getFile(argv, 0);
    if (iof.flags & file_closed != 0) return raise.panic("file is closed");
    var offset: i64 = 0;
    // The arity above makes the C original's `argc >= 2` test always true.
    const whence_sym = try arglayer.getKeyword(argv, 1);
    const whence = seekWhence(whence_sym, c.janet_string_length(whence_sym));
    if (whence < 0) {
        return pp_format.panicf("expected one of :cur, :set, :end, got %v", .{argv[1]});
    }
    if (argc == 3) offset = try arglayer.getInteger64(argv, 2);
    if (seekStream(streamOf(iof), offset, whence) != 0) return raise.panic("error seeking file");
    return argv[0];
}

fn cfunFtell(argc: i32, argv: [*c]c.Janet) align(corefn.alignment) raise.Raising(c.Janet) {
    try arglayer.fixarity(argc, 1);
    const iof = try getFile(argv, 0);
    if (iof.flags & file_closed != 0) return raise.panic("file is closed");
    const pos = tellStream(streamOf(iof));
    if (pos == -1) return raise.panic("error getting position in file");
    return c.janet_wrap_number(@floatFromInt(pos));
}

/// The method table `(:read f ...)` and `(keys f)` both walk.
///
/// `janet_getmethod` scans it linearly, so the order is what `janet_nextmethod`
/// reports and is part of the contract rather than a tidiness; Part 7 recorded
/// the same thing about the parser's table after a mutation survived.
const file_methods = [_]corefn.Method{
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

export fn janet_dynfile(name: [*c]const u8, def: ?*FILE) callconv(.c) ?*FILE {
    const x = c.janet_dyn(name);
    if (c.janet_checktype(x, c.JANET_ABSTRACT) == 0) return def;
    const abstract = c.janet_unwrap_abstract(x);
    if (c.janet_abstract_type(abstract) != abstract_type.stored(&janet_file_type)) return def;
    const iof: *c.JanetFile = @ptrCast(@alignCast(abstract));
    return @ptrCast(iof.file);
}

/// Print `argv[offset..]` to `x`, which may be a buffer, a function, a file,
/// or nil for the default handle.
///
/// An abstract that is not a file is silently ignored -- it returns nil having
/// printed nothing -- which is the C original's and is why the `default` arm
/// below cannot simply own every non-file case.
fn printImplX(
    argc: i32,
    argv: [*c]c.Janet,
    newline: bool,
    dflt_file: ?*FILE,
    offset: i32,
    x: c.Janet,
) raise.Raising(c.Janet) {
    var f: ?*FILE = null;
    switch (c.janet_type(x)) {
        c.JANET_BUFFER => {
            // Special case buffer
            const buf = c.janet_unwrap_buffer(x);
            var i: i32 = offset;
            while (i < argc) : (i += 1) try printer.toStringB(buf, argv[@intCast(i)]);
            if (newline) try containers.bufferPushU8(buf, '\n');
            return c.janet_wrap_nil();
        },
        c.JANET_FUNCTION => {
            // Special case function
            const fun = c.janet_unwrap_function(x);
            const buf = c.janet_buffer(0);
            var i: i32 = offset;
            while (i < argc) : (i += 1) try printer.toStringB(buf, argv[@intCast(i)]);
            if (newline) try containers.bufferPushU8(buf, '\n');
            var args = [_]c.Janet{c.janet_wrap_buffer(buf)};
            _ = try vm_entry.callImpl(fun, 1, &args);
            return c.janet_wrap_nil();
        },
        c.JANET_NIL => {
            f = dflt_file;
            if (f == null) return raise.panic("cannot print to nil");
        },
        c.JANET_ABSTRACT => {
            const abstract = c.janet_unwrap_abstract(x);
            if (c.janet_abstract_type(abstract) != abstract_type.stored(&janet_file_type)) return c.janet_wrap_nil();
            const iofile: *c.JanetFile = @ptrCast(@alignCast(abstract));
            try assertWriteable(iofile);
            f = streamOf(iofile);
        },
        else => return pp_format.panicf("cannot print to %v", .{x}),
    }
    var i: i32 = offset;
    while (i < argc) : (i += 1) {
        var len: i32 = undefined;
        var vstr: [*c]const u8 = undefined;
        if (c.janet_checktype(argv[@intCast(i)], c.JANET_BUFFER) != 0) {
            const b = c.janet_unwrap_buffer(argv[@intCast(i)]);
            vstr = b.*.data;
            len = b.*.count;
        } else {
            vstr = c.janet_to_string(argv[@intCast(i)]);
            len = c.janet_string_length(vstr);
        }
        if (len != 0) {
            if (writeStream(f, vstr, @intCast(len)) != 1) {
                if (f == dflt_file) {
                    return pp_format.panicf("cannot print %d bytes", .{len});
                } else {
                    return pp_format.panicf("cannot print %d bytes to %v", .{ len, x });
                }
            }
        }
    }
    if (newline) _ = putCharStream(f, '\n');
    return c.janet_wrap_nil();
}

fn printImpl(
    argc: i32,
    argv: [*c]c.Janet,
    newline: bool,
    name: [*c]const u8,
    dflt_file: ?*FILE,
) raise.Raising(c.Janet) {
    const x = c.janet_dyn(name);
    return printImplX(argc, argv, newline, dflt_file, 0, x);
}

/// `print`, `prin`, `eprint` and `eprin` differ only in the dynamic binding
/// they read and whether they end with a newline.
fn Print(comptime newline: bool, comptime name: [:0]const u8, comptime handle: anytype) type {
    return struct {
        fn cfun(argc: i32, argv: [*c]c.Janet) align(corefn.alignment) raise.Raising(c.Janet) {
            return printImpl(argc, argv, newline, name.ptr, handle());
        }
    };
}

/// `xprint` and `xprin` take the destination as their first argument instead,
/// and have no default handle to fall back on.
fn XPrint(comptime newline: bool) type {
    return struct {
        fn cfun(argc: i32, argv: [*c]c.Janet) align(corefn.alignment) raise.Raising(c.Janet) {
            try arglayer.arity(argc, 1, -1);
            return printImplX(argc, argv, newline, null, 1, argv[0]);
        }
    };
}

fn printfImplX(
    argc: i32,
    argv: [*c]c.Janet,
    newline: bool,
    dflt_file: ?*FILE,
    offset: i32,
    x: c.Janet,
) raise.Raising(c.Janet) {
    var f: ?*FILE = null;
    const fmt = try arglayer.getCString(argv, offset);
    switch (c.janet_type(x)) {
        c.JANET_BUFFER => {
            // Special case buffer
            const buf = c.janet_unwrap_buffer(x);
            try pp_format.bufferFormat(buf, fmt, offset, argc, argv);
            if (newline) try containers.bufferPushU8(buf, '\n');
            return c.janet_wrap_nil();
        },
        c.JANET_FUNCTION => {
            // Special case function
            const fun = c.janet_unwrap_function(x);
            const buf = c.janet_buffer(0);
            try pp_format.bufferFormat(buf, fmt, offset, argc, argv);
            if (newline) try containers.bufferPushU8(buf, '\n');
            var args = [_]c.Janet{c.janet_wrap_buffer(buf)};
            _ = try vm_entry.callImpl(fun, 1, &args);
            return c.janet_wrap_nil();
        },
        c.JANET_NIL => {
            f = dflt_file;
            if (f == null) return raise.panic("cannot print to nil");
        },
        c.JANET_ABSTRACT => {
            const abstract = c.janet_unwrap_abstract(x);
            if (c.janet_abstract_type(abstract) != abstract_type.stored(&janet_file_type)) return c.janet_wrap_nil();
            const iofile: *c.JanetFile = @ptrCast(@alignCast(abstract));
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
    const buf = c.janet_buffer(10);
    try pp_format.bufferFormat(buf, fmt, offset, argc, argv);
    if (newline) try containers.bufferPushU8(buf, '\n');
    if (buf.*.count != 0) {
        if (writeStream(f, buf.*.data, @intCast(buf.*.count)) != 1) {
            return pp_format.panicf("could not print %d bytes to file", .{buf.*.count});
        }
    }
    // Clear buffer to make things easier for GC
    buf.*.count = 0;
    buf.*.capacity = 0;
    c.janet_free(buf.*.data);
    buf.*.data = null;
    return c.janet_wrap_nil();
}

fn printfImpl(
    argc: i32,
    argv: [*c]c.Janet,
    newline: bool,
    name: [*c]const u8,
    dflt_file: ?*FILE,
) raise.Raising(c.Janet) {
    try arglayer.arity(argc, 1, -1);
    const x = c.janet_dyn(name);
    return printfImplX(argc, argv, newline, dflt_file, 0, x);
}

fn Printf(comptime newline: bool, comptime name: [:0]const u8, comptime handle: anytype) type {
    return struct {
        fn cfun(argc: i32, argv: [*c]c.Janet) align(corefn.alignment) raise.Raising(c.Janet) {
            return printfImpl(argc, argv, newline, name.ptr, handle());
        }
    };
}

fn XPrintf(comptime newline: bool) type {
    return struct {
        fn cfun(argc: i32, argv: [*c]c.Janet) align(corefn.alignment) raise.Raising(c.Janet) {
            try arglayer.arity(argc, 2, -1);
            return printfImplX(argc, argv, newline, null, 1, argv[0]);
        }
    };
}

/// Flush a dynamic binding if it names a file, and do nothing at all if it
/// names anything else. Neither `flush` nor `eflush` can fail.
fn flusher(name: [*c]const u8, dflt_file: ?*FILE) void {
    const x = c.janet_dyn(name);
    switch (c.janet_type(x)) {
        c.JANET_NIL => _ = flushStream(dflt_file),
        c.JANET_ABSTRACT => {
            const abstract = c.janet_unwrap_abstract(x);
            if (c.janet_abstract_type(abstract) != abstract_type.stored(&janet_file_type)) return;
            const iofile: *c.JanetFile = @ptrCast(@alignCast(abstract));
            _ = flushStream(streamOf(iofile));
        },
        else => {},
    }
}

fn Flush(comptime name: [:0]const u8, comptime handle: anytype) type {
    return struct {
        fn cfun(argc: i32, argv: [*c]c.Janet) align(corefn.alignment) raise.Raising(c.Janet) {
            try arglayer.fixarity(argc, 0);
            _ = argv;
            flusher(name.ptr, handle());
            return c.janet_wrap_nil();
        }
    };
}

// ==========================================================================
// The public C API
// ==========================================================================

fn janet_getjfileImpl(argv: [*c]const c.Janet, n: i32) raise.Raising(*c.JanetFile) {
    return @ptrCast(@alignCast(try arglayer.getAbstract(argv, n, abstract_type.stored(&janet_file_type))));
}

export fn janet_getjfile(argv: [*c]const c.Janet, n: i32) callconv(.c) *c.JanetFile {
    return raise.reported(janet_getjfileImpl(argv, n));
}

pub fn janet_getfileImpl(argv: [*c]const c.Janet, n: i32, flags: [*c]i32) raise.Raising(?*FILE) {
    const iof: *c.JanetFile = @ptrCast(@alignCast(try arglayer.getAbstract(argv, n, abstract_type.stored(&janet_file_type))));
    if (flags != null) flags.* = iof.flags;
    return @ptrCast(iof.file);
}

export fn janet_getfile(argv: [*c]const c.Janet, n: i32, flags: [*c]i32) callconv(.c) ?*FILE {
    return raise.reported(janet_getfileImpl(argv, n, flags));
}

export fn janet_makejfile(f: ?*FILE, flags: i32) callconv(.c) *c.JanetFile {
    return makef(f, flags, bufsiz);
}

export fn janet_makefile(f: ?*FILE, flags: i32) callconv(.c) c.Janet {
    return c.janet_wrap_abstract(makef(f, flags, bufsiz));
}

export fn janet_checkfile(j: c.Janet) callconv(.c) c.JanetAbstract {
    return c.janet_checkabstract(j, abstract_type.stored(&janet_file_type));
}

export fn janet_unwrapfile(j: c.Janet, flags: [*c]i32) callconv(.c) ?*FILE {
    const iof: *c.JanetFile = @ptrCast(@alignCast(c.janet_unwrap_abstract(j)));
    if (flags != null) flags.* = iof.flags;
    return @ptrCast(iof.file);
}

// ==========================================================================
// Registration
// ==========================================================================

pub fn janet_lib_ioImpl(env: *c.JanetTable) raise.Raising(void) {
    const entries = [_]corefn.Entry{
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
        corefn.end,
    };
    corefn.install(env, &entries);
    try registration.registerAbstractType(abstract_type.stored(&janet_file_type));
    const default_flags: i32 = file_not_closeable | file_serializable;
    corefn.def(env, "stdout", janet_makefile(stdoutFile(), file_append | default_flags), @src(), "The standard output file.");
    corefn.def(env, "stderr", janet_makefile(stderrFile(), file_append | default_flags), @src(), "The standard error file.");
    corefn.def(env, "stdin", janet_makefile(stdinFile(), file_read | default_flags), @src(), "The standard input file.");
}

export fn janet_lib_io(env: *c.JanetTable) callconv(.c) void {
    raise.reported(janet_lib_ioImpl(env));
}

fn scan(mode: []const u8) struct { status: i32, flags: i32, sandbox: u32, index: i32 } {
    var flags: i32 = 0;
    var sandbox_flags: u32 = 0;
    var index: i32 = 0;
    const status = scanMode(mode.ptr, @intCast(mode.len), &flags, &sandbox_flags, &index);
    return .{ .status = status, .flags = flags, .sandbox = sandbox_flags, .index = index };
}

test "mode scanning accepts the documented flags" {
    const r = scan("r");
    try std.testing.expectEqual(mode_ok, r.status);
    try std.testing.expectEqual(file_read, r.flags);
    try std.testing.expectEqual(sandbox_fs_read, r.sandbox);

    const wbn = scan("wbn");
    try std.testing.expectEqual(mode_ok, wbn.status);
    try std.testing.expectEqual(file_write | file_binary | file_nonil, wbn.flags);
    try std.testing.expectEqual(sandbox_fs_write, wbn.sandbox);

    const ap = scan("a+");
    try std.testing.expectEqual(mode_ok, ap.status);
    try std.testing.expectEqual(file_append | file_update, ap.flags);
    try std.testing.expectEqual(sandbox_fs | sandbox_fs_write, ap.sandbox);
}

test "mode scanning reports where it stopped" {
    try std.testing.expectEqual(mode_bad_length, scan("").status);
    try std.testing.expectEqual(mode_bad_length, scan("rbbbbbbbbbb").status);
    try std.testing.expectEqual(mode_bad_first, scan("q").status);
    try std.testing.expectEqual(@as(i32, 0), scan("q").index);

    const later = scan("r+q");
    try std.testing.expectEqual(mode_bad_later, later.status);
    try std.testing.expectEqual(@as(i32, 2), later.index);
    try std.testing.expectEqual(sandbox_fs_read | sandbox_fs_write, later.sandbox);
}

test "a repeated flag yields the flag word the C implementation returned" {
    for ([_][]const u8{ "r++", "rbb", "rnn" }) |mode| {
        const result = scan(mode);
        try std.testing.expectEqual(mode_repeated, result.status);
        try std.testing.expectEqual(@as(i32, -1), result.flags);
    }
    // The prefix before the repeat still reports its permissions, because the
    // C loop asserted them before reaching the repeated byte.
    try std.testing.expectEqual(sandbox_fs_read | sandbox_fs_write, scan("r++").sandbox);
    try std.testing.expectEqual(sandbox_fs_read, scan("rbb").sandbox);
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
