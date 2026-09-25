//! Files: the `core/file` abstract type and its five callbacks, the
//! twenty-two nfunctions of the `file/` and `print`/`printf` families, the
//! public `File` entry points, the mode-string kernels, the stream host
//! operations, and the registration.
//!
//! Every raise here is an error return: an nfunction that decides to raise
//! returns `raise.Error!Value`, and one that makes no such decision is
//! written as the plain `raise.NFunction` it is. Twenty of the twenty-two
//! raise; the two that cannot are `flush` and `eflush`, whose three arms are
//! flush it, flush the default handle, and do nothing.
//!
//! `FILE` is opaque by definition, so a stream crosses the kernel boundary as
//! a handle rather than as a structure. There is one spelling of it,
//! `host.FILE`, for the reason `host.zig` gives: two declarations of a host
//! type in one program is a silent mismatch rather than a compile error.
//!
//! `struct stat` is the structure this file does not read. `file/open` rejects
//! a directory by `fstat`ing the descriptor it just opened, `std.fstat` is `{}`
//! on Linux and `std.Stat` has no Linux arm, and the two ways a Zig frame
//! could get one anyway are both refused elsewhere in this tree: a second
//! `@cImport` over `<sys/stat.h>` is the duplicate translation the
//! single-translation rule prevents, and a hand-written layout per platform is
//! guesswork. So the test lives in `os/fs/host_stat.zig`, beside the other
//! reader of a host stat structure, and this file imports it.
//!
//! The sixteen stream kernels are ordinary Zig functions. Each wraps one libc
//! call, so that an nfunction deals in a `?*FILE` and the Windows arm of a call
//! is written once. The stream is optional throughout them, because a closed
//! `File` stores a null, and no caller here reaches one: `flusher` skips a
//! closed file rather than handing `c.fflush` a null, which would flush every
//! output stream in the process; `fileUnmarshal` skips the buffer-size
//! restoration when `c.fdopen` failed, because `c.setvbuf(NULL, ...)` is
//! undefined; and `getFile` raises before it hands one out. The optional stays
//! because the type is what says the null is a state rather than an accident.

// ==========================================================================
// Standard library imports
// ==========================================================================

const std = @import("std");
const builtin = @import("builtin");

// ==========================================================================
// Project imports
// ==========================================================================

const abi = @import("abi");
const abstract_type = @import("../api/abstract_type.zig");
const abstracts = @import("value/abstracts.zig");
const args_core = @import("args.zig");
const buffers = @import("value/buffers.zig");
const c = @import("cabi");
const constants = @import("constants");
const corefn = @import("corefn.zig");
const host = @import("host");
const host_stat = @import("os/fs/host_stat.zig");
const marsh = @import("marsh.zig");
const method_type = @import("method_type.zig");
const pp_describe = @import("pp.zig");
const pp_format = @import("pp/format.zig");
const raise = @import("../api/raise.zig");
const registry = @import("registry.zig");
const repr = @import("repr");
const stdio = @import("stdio.zig");
const strings = @import("value/strings.zig");
const tables = @import("value/tables.zig");
const utils = @import("utils.zig");
const vm_entry = @import("vm/entry.zig");
const vm_lifecycle = @import("vm/lifecycle.zig");
const vm_state = @import("vm/state.zig");
const wrap = @import("value/helpers/wrap.zig");

// ==========================================================================
// Constants
// ==========================================================================

/// The C library's default buffer size, which `file/open` compares against to
/// decide whether the caller asked for a different one.
const bufsiz: usize = c.BUFSIZ;

/// libc's end-of-file marker.
const eof: i32 = c.EOF;

/// The single fd flag POSIX defines.
const fd_cloexec: c_int = 1;

/// The abstract type `file/open` returns, and what `getfile` checks an
/// argument against.
pub const fileType = abstract_type.define(File, .{
    .name = "core/file",
    .gc = fileGC,
    .get = fileGet,
    .marshal = fileMarshal,
    .unmarshal = fileUnmarshal,
    .next = fileNext,
});

/// The four flags the mode scanner produces, and the two it can be asked for
/// beside them. The three the abstract sets for itself are below.
const file_append: i32 = 4;
const file_binary: i32 = 64;
const file_nonil: i32 = 512;
const file_read: i32 = 2;
const file_update: i32 = 8;
const file_write: i32 = 1;

/// The flags the abstract type sets that a mode string cannot ask for.
const file_closed: i32 = 32;
const file_not_closeable: i32 = 16;
const file_serializable: i32 = 128;

/// The method table `(:read f ...)` and `(keys f)` both walk.
///
/// `findMethod` scans it linearly, so the order here is the order `nextmethod`
/// reports and a caller may depend on it.
const file_methods = [_]method_type.Method{
    .{ .name = "close", .nfun = nfunFclose },
    .{ .name = "flush", .nfun = nfunFflush },
    .{ .name = "read", .nfun = nfunFread },
    .{ .name = "seek", .nfun = nfunFseek },
    .{ .name = "tell", .nfun = nfunFtell },
    .{ .name = "write", .nfun = nfunFwrite },
    .{ .name = null, .nfun = null },
};

/// Full buffering and no buffering, as `setvbuf` spells them. `_IONBF` is 2 in
/// the POSIX C libraries and 4 in the Microsoft one.
const iofbf: c_int = 0;
const ionbf: c_int = if (windows) 4 else 2;

/// What `scanMode` reports. This is the only place these codes are written
/// down; `test/io_core.zig` names them rather than restating the numbers.
pub const mode_bad_first: i32 = 2;
pub const mode_bad_later: i32 = 3;
pub const mode_bad_length: i32 = 1;
pub const mode_ok: i32 = 0;
pub const mode_repeated: i32 = 4;

/// The most bytes a mode string handed to `fopen` occupies, including the `b`
/// Windows adds to it and the terminator. `scanMode` bounds a mode keyword at
/// ten.
const mode_buf_len: usize = 12;

/// Whether this is a Plan 9 build. `c.dup` takes a second argument there and
/// `c.fopen` needs no close-on-exec fixup; both branches are unreachable from
/// Zig, because Plan 9 is not one of this project's targets, and are recorded
/// rather than written. `math.zig` reads its own gate the same way.
const plan9 = (builtin.os.tag == .plan9);

/// `SEEK_SET`, `SEEK_CUR` and `SEEK_END` are 0, 1 and 2 on every platform
/// Janet builds for, but they are host constants, so the boundary takes the
/// position of the keyword in `whence_names` instead and the mapping happens
/// here.
const seek_cur: c_int = 1;
const seek_end: c_int = 2;
const seek_set: c_int = 0;

/// The seek origins a keyword may name, in the order the boundary numbers
/// them.
const whence_names = [_][:0]const u8{ "cur", "set", "end" };

/// Whether this target is Windows, which spells four of the calls below
/// differently.
const windows = builtin.os.tag == .windows;

/// The function writes to standard output and standard error are passed to
/// in place of the stream, or null for none. `divert` sets it.
///
/// Thread-local, because a line editor holds the terminal for the thread that
/// runs its REPL, and a write from another thread goes to its stream as it
/// would with no editor.
threadlocal var diverted: ?Diversion = null;

// ==========================================================================
// Aliased types
// ==========================================================================

/// libc's `FILE`, from `host.zig` rather than declared again here.
///
/// A second local `opaque {}` would be ABI-identical and still a distinct Zig
/// type, and nothing would compare the two. Naming the one declaration is what
/// keeps the question from arising.
pub const FILE = host.FILE;

/// A function that writes bytes meant for standard output or standard error.
///
/// `divert` takes a `Diversion`. It is passed the stream and the bytes, and
/// returns whether it wrote them, or null to leave them to the stream.
pub const Diversion = *const fn (stream: Standard, bytes: []const u8) ?bool;

// ==========================================================================
// Types
// ==========================================================================

/// A `core/file`: the stream, the flag word, and the buffer size a caller
/// asked for.
pub const File = struct {
    file: ?*host.FILE = null,
    flags: i32 = 0,
    vbufsize: usize = 0,
};

/// Which of the two standard output streams a write is for.
///
/// A `Diversion` is passed a `Standard`.
pub const Standard = enum { out, err };

// ==========================================================================
// Public functions
// ==========================================================================

/// Refuses a file that is closed or was not opened for writing.
pub fn assertWriteable(iof: *File) raise.Error!void {
    if (iof.flags & file_closed != 0) return raise.panic("file is closed");
    if (iof.flags & (file_write | file_append | file_update) == 0) {
        return raise.panic("file is not writeable");
    }
}

/// The payload of a file value, or null where the value is not a file.
pub fn checkfile(j: repr.Value) ?abstracts.Abstract {
    return args_core.checkabstract(j, &fileType);
}

/// `fclose`.
pub fn close(file: ?*FILE) i32 {
    return c.fclose(file);
}

/// Passes writes to standard output and standard error to `diversion`, or
/// passes them to the streams again when `diversion` is null.
///
/// Both streams are flushed first, so bytes they buffered before the call are
/// written before any the diversion writes. The diversion applies to `write`
/// and `putChar` on the calling thread. This function cannot raise.
///
/// A line editor installs a diversion while it holds a line, so that output
/// is written above the line rather than into it.
pub fn divert(diversion: ?Diversion) void {
    _ = c.fflush(stdoutFile());
    _ = c.fflush(stderrFile());
    diverted = diversion;
}

/// The stream a dynamic binding names, or `def` where it names anything but a
/// file.
pub fn dynfile(name: [*:0]const u8, def: ?*FILE) ?*FILE {
    const x = vm_state.dyn(name);
    if (!repr.checkType(x, repr.Tag.abstract)) return def;
    const abstract = wrap.toAbstract(x);
    if (abi.abstractHead(abstract).type != &fileType) return def;
    const iof: *File = @ptrCast(@alignCast(abstract));
    return @ptrCast(iof.file);
}

/// `ferror`.
pub fn err(file: ?*FILE) i32 {
    return c.ferror(file);
}

/// Closes a file from another subsystem, reporting the host's result.
pub fn fileClose(file: *File) c_int {
    return closeFile(file);
}

/// `fflush`.
pub fn flush(file: ?*FILE) i32 {
    return c.fflush(file);
}

/// Reads one byte, or returns `EOF`.
pub fn getChar(file: ?*FILE) i32 {
    return c.fgetc(file);
}

/// The stream of a file argument, or a raise where there is none.
///
/// A closed file has no stream, and this is where that is said. Closing nulls
/// the pointer deliberately, and every nfunction in this file tests the closed
/// flag before it touches a stream, but a caller outside the file reaching
/// through this accessor has no flag word unless it asks for one, so without
/// the test a caller that does not ask hands `fileno` a null. The test belongs
/// here, where every such caller inherits it.
pub fn getfile(argv: []const repr.Value, n: usize, flags: ?*i32) raise.Error!?*FILE {
    const iof: *File = try args_core.getAbstract(File, argv, n, &fileType);
    if (flags) |slot| slot.* = iof.flags;
    if (iof.flags & file_closed != 0) return raise.panic("file is closed");
    return @ptrCast(iof.file);
}

/// The `File` payload of a file argument, for a caller that needs the flags
/// rather than the stream.
pub fn getjfile(argv: []const repr.Value, n: usize) raise.Error!*File {
    return try args_core.getAbstract(File, argv, n, &fileType);
}

/// Registers the `file/` and `print`/`printf` families, and the three standard
/// streams.
pub fn libIo(env: *tables.Table) raise.Error!void {
    const entries = comptime [_]corefn.Entry{
        corefn.reg("print", &Print(true, "out", stdoutFile).nfun, @src(), "(print & xs)", "Prints values to the console (standard out). Value are converted " ++
            "to strings if they are not already. After printing all values, a " ++
            "newline character is printed. The value of `(dyn :out stdout)` determines " ++
            "what to push characters to. Expects `(dyn :out stdout)` to be either a core/file or " ++
            "a buffer. Returns nil."),
        corefn.reg("prin", &Print(false, "out", stdoutFile).nfun, @src(), "(prin & xs)", "Same as `print`, but does not add trailing newline."),
        corefn.reg("printf", &Printf(true, "out", stdoutFile).nfun, @src(), "(printf fmt & xs)", "Prints output formatted as if with `(string/format fmt ;xs)` to `(dyn :out stdout)` with a trailing newline."),
        corefn.reg("prinf", &Printf(false, "out", stdoutFile).nfun, @src(), "(prinf fmt & xs)", "Like `printf` but with no trailing newline."),
        corefn.reg("eprin", &Print(false, "err", stderrFile).nfun, @src(), "(eprin & xs)", "Same as `prin`, but uses `(dyn :err stderr)` instead of `(dyn :out stdout)`."),
        corefn.reg("eprint", &Print(true, "err", stderrFile).nfun, @src(), "(eprint & xs)", "Same as `print`, but uses `(dyn :err stderr)` instead of `(dyn :out stdout)`."),
        corefn.reg("eprintf", &Printf(true, "err", stderrFile).nfun, @src(), "(eprintf fmt & xs)", "Prints output formatted as if with `(string/format fmt ;xs)` to `(dyn :err stderr)` with a trailing newline."),
        corefn.reg("eprinf", &Printf(false, "err", stderrFile).nfun, @src(), "(eprinf fmt & xs)", "Like `eprintf` but with no trailing newline."),
        corefn.reg("xprint", &XPrint(true).nfun, @src(), "(xprint to & xs)", "Prints to a file or other value explicitly (no dynamic bindings) with a trailing " ++
            "newline character. The value to print " ++
            "to is the first argument, and is otherwise the same as `print`. Returns nil."),
        corefn.reg("xprin", &XPrint(false).nfun, @src(), "(xprin to & xs)", "Prints to a file or other value explicitly (no dynamic bindings). The value to print " ++
            "to is the first argument, and is otherwise the same as `prin`. Returns nil."),
        corefn.reg("xprintf", &XPrintf(true).nfun, @src(), "(xprintf to fmt & xs)", "Like `printf` but prints to an explicit file or value `to`. Returns nil."),
        corefn.reg("xprinf", &XPrintf(false).nfun, @src(), "(xprinf to fmt & xs)", "Like `prinf` but prints to an explicit file or value `to`. Returns nil."),
        corefn.reg("flush", &Flush("out", stdoutFile).nfun, @src(), "(flush)", "Flushes `(dyn :out stdout)` if it is a file, otherwise does nothing."),
        corefn.reg("eflush", &Flush("err", stderrFile).nfun, @src(), "(eflush)", "Flushes `(dyn :err stderr)` if it is a file, otherwise does nothing."),
        corefn.reg("file/temp", &nfunTemp, @src(), "(file/temp)", "Opens an anonymous temporary file that is removed on close. " ++
            "Raises an error on failure."),
        corefn.reg("file/open", &nfunFopen, @src(), "(file/open path [mode [buffer-size]])", "Opens a file. `path` is an absolute or relative path, and " ++
            "`mode` is a set of flags indicating the mode to open the file in. " ++
            "`mode` is a keyword where each character represents a flag. If the file " ++
            "cannot be opened, returns nil, otherwise returns the new file handle. " ++
            "Mode flags:\n\n" ++
            "* r - allow reading from the file\n\n" ++
            "* w - allow writing to the file\n\n" ++
            "* a - append to the file\n\n" ++
            "Following one of the initial flags, 0 or more of the following flags can be appended:\n\n" ++
            "* b - accepted and has no effect: a file is always opened in binary mode\n\n" ++
            "* + - append to the file instead of overwriting it\n\n" ++
            "* n - error if the file cannot be opened instead of returning nil\n\n" ++
            "See fopen (<stdio.h>, C99) for further details."),
        corefn.reg("file/close", &nfunFclose, @src(), "(file/close f)", "Closes a file and releases all related resources. Closing a file " ++
            "after reading prevents a resource leak and lets " ++
            "other processes read the file."),
        corefn.reg("file/read", &nfunFread, @src(), "(file/read f what [buf])", "Reads a number of bytes from a file `f` into a buffer. A buffer `buf` can " ++
            "be provided as an optional third argument, otherwise a new buffer " ++
            "is created. `what` can either be an integer or a keyword. Returns the " ++
            "buffer with file contents. " ++
            "Values for `what`:\n\n" ++
            "* :all - read the whole file\n\n" ++
            "* :line - read up to and including the next newline character\n\n" ++
            "* n (integer) - read up to n bytes from the file"),
        corefn.reg("file/write", &nfunFwrite, @src(), "(file/write f & bytes)", "Writes to a file `f`. Each value of `bytes` must be a " ++
            "string, buffer, symbol, or keyword. Returns the file."),
        corefn.reg("file/flush", &nfunFflush, @src(), "(file/flush f)", "Flushes any buffered bytes to the file system. In most files, writes are " ++
            "buffered for efficiency reasons. Returns the file handle."),
        corefn.reg("file/seek", &nfunFseek, @src(), "(file/seek f [whence [n]])", "Jumps to a relative location in the file `f`. `whence` must be one of:\n\n" ++
            "* :cur - jump relative to the current file location\n\n" ++
            "* :set - jump relative to the beginning of the file\n\n" ++
            "* :end - jump relative to the end of the file\n\n" ++
            "By default, `whence` is :cur. Optionally a value `n` may be passed " ++
            "for the relative number of bytes to seek in the file. `n` may be a real " ++
            "number to handle large files of more than 4GB. Returns the file handle."),
        corefn.reg("file/tell", &nfunFtell, @src(), "(file/tell f)", "Gets the current value of the file position for file `f`."),
    };
    corefn.install(env, entries);
    try registry.registerAbstractType(&fileType);
    const default_flags: i32 = file_not_closeable | file_serializable;
    corefn.def(env, "stdout", makefile(stdoutFile(), file_append | default_flags), @src(), "The standard output file.");
    corefn.def(env, "stderr", makefile(stderrFile(), file_append | default_flags), @src(), "The standard error file.");
    corefn.def(env, "stdin", makefile(stdinFile(), file_read | default_flags), @src(), "The standard input file.");
}

/// A stream wrapped as a file value, with the default buffer size.
pub fn makefile(f: ?*FILE, flags: i32) repr.Value {
    return wrap.fromAbstract(makef(f, flags, bufsiz));
}

/// The same, as the payload rather than the value. `os/process.zig` reaches
/// this by import.
pub fn makejfile(f: ?*FILE, flags: i32) *File {
    return makef(f, flags, bufsiz);
}

/// Rebuilds the `c.fopen` mode a flag word came from, for reattaching a
/// marshalled descriptor. Writes at most three bytes plus a terminator into
/// `out` and returns the length.
///
/// This is not the inverse of `scanMode`: it drops the binary, update and
/// no-nil flags, and it collapses append and write, because all `c.fdopen` has
/// to do is accept the result.
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

/// `fopen`.
pub fn open(path: [*:0]const u8, mode: [*:0]const u8) ?*FILE {
    return c.fopen(path, mode);
}

/// `fputc`, or the diversion `divert` installed when `file` is standard
/// output or standard error.
pub fn putChar(file: ?*FILE, ch: i32) i32 {
    if (diverted) |diversion| {
        if (standardOf(file)) |stream| {
            const byte = [1]u8{@truncate(@as(u32, @bitCast(ch)))};
            if (diversion(stream, &byte)) |wrote| return if (wrote) ch else eof;
        }
    }
    return c.fputc(ch, file);
}

/// Reads up to `count` bytes, reporting how many arrived. A short read is not
/// by itself a failure, so a caller consults `err` afterwards.
pub fn read(file: ?*FILE, dest: [*]u8, count: usize) usize {
    return c.fread(dest, 1, count, file);
}

/// Classifies a `file/open` mode string.
///
/// Reports the flag word, the sandbox permissions the accepted prefix implies,
/// and where the scan stopped. The ordering matters: the caller asserts the
/// permissions and then raises, so the permissions accumulate only over the
/// bytes reached before the scan stopped, and a sandbox denial for a prefix
/// comes out before the complaint about a later bad byte.
///
/// A repeated flag is reported as `mode_repeated` with a flag word of -1, and
/// -1 is not a flag word: `checkFlags` raises on it rather than passing it on.
/// Every bit set includes `file_closed` and `file_not_closeable`, which is a
/// handle that reports itself closed, refuses every operation, refuses to be
/// closed, and so never gives up its descriptor.
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

/// Moves the file position, with `whence` given as a position in
/// `whence_names`. An unrecognised origin cannot reach here: a caller rejects
/// it while the keyword to name in the panic is still to hand.
pub fn seek(file: ?*FILE, offset: i64, whence: i32) i32 {
    const origin: c_int = switch (whence) {
        0 => seek_cur,
        1 => seek_set,
        else => seek_end,
    };
    if (windows) return c._fseeki64(file, offset, origin);
    // `fseeko`, not `fseek`: the docstring promises files of more than 4GB,
    // and `long` is 32 bits on a 32-bit POSIX host where `off_t` is 64. On a
    // 64-bit host the two are the same call.
    return c.fseeko(file, offset, origin);
}

/// Finds a seek origin by keyword, returning its position or -1.
///
/// The comparison is `utils.cstrcmp`'s walk written as an equality test: the
/// key's own length bounds it, and a NUL in the name ends it.
pub fn seekWhence(key: [*]const u8, len: usize) i32 {
    for (whence_names, 0..) |name, index| {
        if (cstrequal(key, len, name)) return @intCast(index);
    }
    return -1;
}

/// Selects full buffering of `size` bytes, or no buffering when `size` is
/// zero.
pub fn setBufferSize(file: ?*FILE, size: usize) i32 {
    return c.setvbuf(file, null, if (size != 0) iofbf else ionbf, size);
}

/// `ftell`, widened on Windows.
pub fn tell(file: ?*FILE) i64 {
    if (windows) return c._ftelli64(file);
    return c.ftello(file);
}

/// `tmpfile`.
///
/// WASI has no `tmpfile`, and wasi-libc declares `mkstemp` without defining
/// it, so there the file is made here: a random name in the working directory,
/// created with `O_EXCL` so that an existing file is refused rather than
/// opened, and unlinked at once, so that, as with `tmpfile`, it is gone when
/// the stream closes. The working directory, and not `$TMPDIR` or `/tmp`,
/// because a WASI program sees only the directories its host maps in, and
/// `wasmtime run --dir .` maps in that one.
pub fn temp() ?*FILE {
    if (builtin.os.tag == .wasi) {
        const digits = "0123456789abcdefghijklmnopqrstuvwxyz";
        var name = "wattle-tmp-XXXXXXXX".*;
        const suffix = name.len - 8;
        var attempt: usize = 0;
        while (attempt < 8) : (attempt += 1) {
            var bytes: [8]u8 = undefined;
            if (utils.cryptorand(&bytes, bytes.len) != 0) return null;
            for (bytes, 0..) |byte, i| name[suffix + i] = digits[byte % digits.len];
            const fd = std.c.open(&name, .{ .CREAT = true, .EXCL = true, .read = true, .write = true }, @as(c_uint, 0o600));
            if (fd < 0) continue;
            _ = c.unlink(&name);
            return c.fdopen(fd, "w+") orelse {
                _ = c.close(fd);
                return null;
            };
        }
        return null;
    } else {
        return c.tmpfile();
    }
}

/// The stream of a file value the caller has already checked, with no test of
/// the closed flag.
pub fn unwrapfile(j: repr.Value, flags: ?*i32) ?*FILE {
    const iof: *File = @ptrCast(@alignCast(wrap.toAbstract(j)));
    if (flags) |slot| slot.* = iof.flags;
    return @ptrCast(iof.file);
}

/// Writes `count` bytes as a single item, so the result is 1 on success and 0
/// on failure, which is what callers compare against.
///
/// The bytes go to the diversion `divert` installed when `file` is standard
/// output or standard error and the diversion writes them.
pub fn write(file: ?*FILE, src: [*]const u8, count: usize) i32 {
    if (diverted) |diversion| {
        if (standardOf(file)) |stream| {
            if (diversion(stream, src[0..count])) |wrote| return @intFromBool(wrote);
        }
    }
    return @intCast(c.fwrite(src, count, 1, file));
}

// ==========================================================================
// Private functions
// ==========================================================================

/// `flush` and `eflush` differ only in the dynamic binding they read.
fn Flush(comptime name: [:0]const u8, comptime handle: anytype) type {
    return struct {
        fn nfun(argv: []repr.Value) raise.Error!repr.Value {
            try args_core.fixarity(argv, 0);

            flusher(name.ptr, handle());
            return wrap.fromNil();
        }
    };
}

/// `print`, `prin`, `eprint` and `eprin` differ only in the dynamic binding
/// they read and whether they end with a newline.
fn Print(comptime newline: bool, comptime name: [:0]const u8, comptime handle: anytype) type {
    return struct {
        fn nfun(argv: []repr.Value) raise.Error!repr.Value {
            return print(argv, newline, name.ptr, handle());
        }
    };
}

/// `printf`, `prinf`, `eprintf` and `eprinf`, the same four differences.
fn Printf(comptime newline: bool, comptime name: [:0]const u8, comptime handle: anytype) type {
    return struct {
        fn nfun(argv: []repr.Value) raise.Error!repr.Value {
            return printf(argv, newline, name.ptr, handle());
        }
    };
}

/// `xprint` and `xprin` take the destination as their first argument instead,
/// and have no default handle to fall back on.
fn XPrint(comptime newline: bool) type {
    return struct {
        fn nfun(argv: []repr.Value) raise.Error!repr.Value {
            try args_core.arity(argv, 1, -1);
            return printImplX(argv, newline, null, 1, argv[0]);
        }
    };
}

/// `xprintf` and `xprinf`, the same again with a format string.
fn XPrintf(comptime newline: bool) type {
    return struct {
        fn nfun(argv: []repr.Value) raise.Error!repr.Value {
            try args_core.arity(argv, 2, -1);
            return printfImplX(argv, newline, null, 1, argv[0]);
        }
    };
}

/// Copies a mode keyword into `out` with a `b` appended where it has none,
/// and returns the copy.
///
/// `given` is a mode `scanMode` accepted, so it is at most ten bytes and the
/// copy, the `b` and the terminator fit. A mode already naming `b` is copied
/// unchanged. This function cannot raise.
fn binaryMode(given: [*:0]const u8, out: *[mode_buf_len]u8) [*:0]const u8 {
    var len: usize = 0;
    var has_binary = false;
    while (given[len] != 0 and len < out.len - 2) : (len += 1) {
        out[len] = given[len];
        if (out[len] == 'b') has_binary = true;
    }
    if (!has_binary) {
        out[len] = 'b';
        len += 1;
    }
    out[len] = 0;
    return @ptrCast(out);
}

/// `(file/close f)`.
fn nfunFclose(argv: []repr.Value) raise.Error!repr.Value {
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

/// `(file/flush f)`.
fn nfunFflush(argv: []repr.Value) raise.Error!repr.Value {
    try args_core.fixarity(argv, 1);
    const iof = try getFile(argv, 0);
    try assertWriteable(iof);
    if (flush(streamOf(iof)) != 0) return raise.panic("could not flush file");
    return argv[0];
}

/// `(file/open path [mode [buffer-size]])`.
///
/// The file is opened in binary mode on every platform. On Windows the `b`
/// a mode keyword lacks is added before `fopen` sees it, so the `b` flag is
/// accepted and changes nothing.
fn nfunFopen(argv: []repr.Value) raise.Error!repr.Value {
    try args_core.arity(argv, 1, 3);
    const fname = try args_core.getString(argv, 0);
    var fmode: strings.String = undefined;
    var flags: i32 = undefined;
    // The mode is read whenever it is given, whether or not a buffer size
    // follows it. Reading it only at exactly two arguments leaves a three-
    // argument call with an unscanned mode and a read-only handle, so `:wb
    // 4096` opens for reading and `:zzz 4096` is accepted where `:zzz` is not.
    // The sandbox assertion below the branch is the default's; the mode's own
    // is asserted by `checkFlags`.
    if (argv.len >= 2) {
        fmode = try args_core.getKeyword(argv, 1);
        flags = try checkFlags(fmode);
    } else {
        fmode = @ptrCast("r");
        try vm_lifecycle.sandboxAssert(vm_lifecycle.Sandbox.of(&.{"fs_read"}));
        flags = file_read;
    }
    var mode_ptr: [*:0]const u8 = @ptrCast(fmode);
    var mode_buf: [mode_buf_len]u8 = undefined;
    // Windows opens binary whatever the mode asked for. The C library's text
    // mode there writes a newline as CRLF, and `slurp` and `spit` open
    // binary, so a text-mode file would not read back what it wrote.
    if (windows) mode_ptr = binaryMode(mode_ptr, &mode_buf);
    const f = open(@ptrCast(fname), mode_ptr);
    // Windows fails the open for a directory instead of opening one, so the
    // check below never sees it and the path is asked about here. Only where
    // the open already failed, so a successful one pays nothing.
    if (f == null and pathIsDirectory(@ptrCast(fname))) {
        return pp_format.panicf("cannot open directory: %s", .{fname});
    }
    var bufsize: usize = bufsiz;
    if (f) |handle| {
        // The open file is this function's until `makef` below takes it, and
        // each of the three lines between here and there can raise, so one
        // `errdefer` closes it rather than a line at each site. Without it a
        // refused buffer size leaves the file open, which POSIX still unlinks
        // and Windows refuses to.
        errdefer _ = close(streamOfHandle(handle));
        // A directory that `c.fopen` accepted is rejected here. The test is
        // `host_stat.zig`'s rather than this file's: see the note there for
        // why a `struct stat` is read in one place for all four targets.
        if (host_stat.isDirectory(handle)) {
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

/// `(file/read f what [buf])`, where `what` is `:all`, `:line` or a byte
/// count.
///
/// The readability test covers all three arms rather than the two that go
/// through `readChunk`. `:line` reads with `getChar`, so a test living only in
/// `readChunk` would leave `:line` giving back `nil` on a write-only file, and
/// that `nil` is not an empty line: it is `getc` on a stream opened for
/// writing, which C99 leaves undefined.
fn nfunFread(argv: []repr.Value) raise.Error!repr.Value {
    try args_core.arity(argv, 2, 3);
    const iof = try getFile(argv, 0);
    if (iof.flags & file_closed != 0) return raise.panic("file is closed");
    // All three arms, not the two that go through `readChunk`. `:line` reads
    // with `getChar` rather than `readChunk`, so a readability test living
    // only in `readChunk` would leave `:line` giving back `nil` on a
    // write-only file, and that `nil` is not an empty line: it is `getc` on a
    // stream opened for writing, which C99 leaves undefined.
    if (iof.flags & (file_read | file_update) == 0) {
        return raise.panic("file is not readable");
    }
    const buffer = if (argv.len == 2) buffers.new(0) else try args_core.getBuffer(argv, 2);
    const bufstart = buffer.count;
    if (wrap.isKeyword(argv[1])) {
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

/// `(file/seek f whence [n])`.
fn nfunFseek(argv: []repr.Value) raise.Error!repr.Value {
    try args_core.arity(argv, 2, 3);
    const iof = try getFile(argv, 0);
    if (iof.flags & file_closed != 0) return raise.panic("file is closed");
    var offset: i64 = 0;
    // The arity above guarantees a second argument, so nothing tests for one.
    const whence_sym = try args_core.getKeyword(argv, 1);
    const whence = seekWhence(whence_sym, strings.head(whence_sym).length);
    if (whence < 0) {
        return pp_format.panicf("expected one of :cur, :set, :end, got %v", .{argv[1]});
    }
    if (argv.len == 3) offset = try args_core.getInteger64(argv, 2);
    if (seek(streamOf(iof), offset, whence) != 0) return raise.panic("error seeking file");
    return argv[0];
}

/// `(file/tell f)`.
fn nfunFtell(argv: []repr.Value) raise.Error!repr.Value {
    try args_core.fixarity(argv, 1);
    const iof = try getFile(argv, 0);
    if (iof.flags & file_closed != 0) return raise.panic("file is closed");
    const pos = tell(streamOf(iof));
    if (pos == -1) return raise.panic("error getting position in file");
    return wrap.fromNumber(@floatFromInt(pos));
}

/// `(file/write f & xs)`. Every argument is checked before any byte is
/// written, so a bad argument leaves the file untouched.
fn nfunFwrite(argv: []repr.Value) raise.Error!repr.Value {
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

/// `(file/temp)`.
fn nfunTemp(argv: []repr.Value) raise.Error!repr.Value {
    try vm_lifecycle.sandboxAssert(vm_lifecycle.Sandbox.of(&.{"fs_temp"}));

    try args_core.fixarity(argv, 0);
    // XXX use mkostemp when we can to avoid CLOEXEC race.
    const tmp = temp() orelse {
        return pp_format.panicf("unable to create temporary file - %s", .{utils.strerrorSafe(c.errno())});
    };
    return makefile(@ptrCast(tmp), file_write | file_read | file_binary);
}

/// Scans a `file/open` mode string and raises what it reports.
///
/// The interleaving is what a caller depends on: the permissions the accepted
/// prefix implies are asserted before a later bad flag is reported, so a
/// sandboxed build refuses `:wq` for the sandbox rather than for the `q`.
fn checkFlags(str: strings.String) raise.Error!i32 {
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
    // A repeat gets its own message: naming `+` as one of the flags expected
    // while refusing a `+` would be no diagnosis at all.
    if (status == mode_repeated) {
        return pp_format.panicf("repeated flag %c in file mode", .{@as(c_int, str[@intCast(index)])});
    }
    return flags;
}

/// Closes a file, reporting the host's result.
///
/// A file that is already closed, or that this runtime only borrowed, reports
/// success and is left alone. The stream pointer is cleared on the way out, so
/// a later use is a null dereference rather than a read of a freed `FILE`.
fn closeFile(file: *File) c_int {
    if (file.flags & (file_not_closeable | file_closed) == 0) {
        const ret = close(streamOf(file));
        file.flags |= file_closed;
        file.file = null;
        return ret;
    }
    return 0;
}

/// Whether the `len` bytes at `key` are `other`, with a NUL in `other` ending
/// the comparison.
fn cstrequal(key: [*]const u8, len: usize, other: [:0]const u8) bool {
    var index: usize = 0;
    while (index < len) : (index += 1) {
        const k = other.ptr[index];
        if (key[index] != k) return false;
        if (k == 0) break;
    }
    return other.ptr[index] == 0;
}

/// Prints where and why, then ends the process.
///
/// The location reported is this file's, through the caller's `@src()`, and
/// there is no preprocessor override an embedder could substitute. The message
/// is assembled at compile time and written with `c.fwrite` rather than handed
/// to `fprintf`, because `fprintf` takes the translated `FILE *` and this file
/// deliberately does not name that type.
fn exitWith(comptime where: std.builtin.SourceLocation, comptime message: []const u8) noreturn {
    const line = std.fmt.comptimePrint(
        "wattle abort at {s}:{d}: {s}\n",
        .{ where.file, where.line, message },
    );
    _ = write(stderrFile(), line.ptr, line.len);
    c.abort();
}

/// Closes the stream when the abstract is collected.
fn fileGC(iof: *File, _: usize) void {
    _ = closeFile(iof);
}

/// The method lookup behind `(:read f ...)` and its siblings.
fn fileGet(_: *File, key: repr.Value) raise.Error!?repr.Value {
    return args_core.findMethod(key, @ptrCast(&file_methods));
}

/// Writes a live descriptor into the stream, which only an unsafe marshal may
/// do. A closeable file is duplicated so that the marshalled copy owns its own
/// descriptor; a borrowed file, `stdout` and its kin, is written as it stands.
/// WASI has no `dup`, so there a closeable file raises.
fn fileMarshal(iof: *File, m: *abi.Marshal) raise.Error!void {
    if (marsh.marshalFlags(m) & constants.marshal_unsafe == 0) {
        return raise.panic("cannot marshal file in safe mode");
    }
    const borrowed = iof.flags & file_not_closeable != 0;
    if (builtin.os.tag == .wasi and !borrowed) {
        return raise.panic("cannot marshal a closeable file on WASI");
    }
    marsh.marshalAbstract(m, iof);
    const fno: c_int = if (builtin.os.tag == .wasi)
        c.fileno(streamOf(iof))
    else if (windows)
        (if (borrowed) c._fileno(streamOf(iof)) else c._dup(c._fileno(streamOf(iof))))
    else
        (if (borrowed) c.fileno(streamOf(iof)) else c.dup(c.fileno(streamOf(iof))));
    try marsh.marshalInt(m, @intCast(fno));
    try marsh.marshalInt(m, iof.flags);
    try marsh.marshalSize(m, iof.vbufsize);
}

/// The iteration order behind `next` and `(keys f)`.
fn fileNext(_: *File, key: repr.Value) raise.Error!repr.Value {
    return args_core.nextmethod(@ptrCast(&file_methods), key);
}

/// Reattaches a descriptor read back out of a stream.
///
/// The mode is rebuilt from the flag word rather than written to the stream,
/// which is what makes `modeFromFlags` something other than the inverse of
/// `scanMode`: `c.fdopen` only has to accept it.
fn fileUnmarshal(u: *abi.Unmarshal) raise.Error!*File {
    if (marsh.unmarshalFlags(u) & constants.marshal_unsafe == 0) {
        return raise.panic("cannot unmarshal file in safe mode");
    }
    const iof: *File = @ptrCast(@alignCast(try marsh.unmarshalAbstract(u, @sizeOf(File))));
    const fd = try marsh.unmarshalInt(u);
    const flags = try marsh.unmarshalInt(u);
    var fmt: [4]u8 = undefined;
    _ = modeFromFlags(flags, &fmt);
    // A descriptor that is not open is refused before `fdopen`, because musl's
    // `fdopen` does not check one for a read or write mode, where macOS's and
    // glibc's do. Either way the file comes back closed.
    const reopened = if (windows)
        c._fdopen(fd, @ptrCast(&fmt))
    else if (std.c.fcntl(fd, std.c.F.GETFD) == -1)
        null
    else
        c.fdopen(fd, @ptrCast(&fmt));
    setStreamOf(iof, reopened);
    iof.flags = if (reopened == null) file_closed else flags;
    iof.vbufsize = try marsh.unmarshalSize(u);
    // Only when there is a stream to set it on. A failed `fdopen` set the
    // closed flag above, and `setvbuf` has no meaning for a null stream.
    if (reopened != null and iof.vbufsize != bufsiz) {
        if (setBufferSize(reopened, iof.vbufsize) != 0) {
            exitWith(@src(), "unmarshal setvbuf");
        }
    }
    return iof;
}

/// Flushes a dynamic binding where it names a file, and does nothing at all
/// where it names anything else. Neither `flush` nor `eflush` can fail.
fn flusher(name: [*:0]const u8, dflt_file: ?*FILE) void {
    const x = vm_state.dyn(name);
    switch (repr.typeOf(x)) {
        repr.Tag.nil => _ = flush(dflt_file),
        repr.Tag.abstract => {
            const abstract = wrap.toAbstract(x);
            if (abi.abstractHead(abstract).type != &fileType) return;
            const iofile: *File = @ptrCast(@alignCast(abstract));
            // A closed file is skipped. Its stream is null, and
            // `fflush(NULL)` is not an error in C99: it flushes every stream
            // open for output in the process, which is not what naming one
            // closed file asks for.
            if (iofile.flags & file_closed != 0) return;
            _ = flush(streamOf(iofile));
        },
        else => {},
    }
}

/// The `File` payload at `argv[n]`, or a raise where that argument is not a
/// file.
fn getFile(argv: []repr.Value, n: usize) raise.Error!*File {
    return try args_core.getAbstract(File, argv, n, &fileType);
}

/// Wraps a stream in the abstract that owns it.
///
/// `c.fopen` has no standard way to ask for close-on-exec, since the `e` mode
/// flag is a GNU extension, so a file this runtime will close is marked
/// separately and a file it only borrows is left alone.
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

/// Whether `path` names a directory, asked of the filesystem rather than of an
/// open descriptor.
///
/// Reports false away from Windows, which is the one platform that calls it:
/// `nfunFopen` asks it where `fopen` failed, and `host_stat.isDirectory`
/// needs a stream that a directory there never yields. This function cannot
/// raise.
fn pathIsDirectory(path: [*:0]const u8) bool {
    if (!windows) return false;
    // `INVALID_FILE_ATTRIBUTES` is `0xFFFF_FFFF` and
    // `FILE_ATTRIBUTE_DIRECTORY` is `0x10`. `os/fs.zig` spells the first as
    // the number too.
    const attributes = c.GetFileAttributesA(path);
    if (attributes == 0xFFFF_FFFF) return false;
    return attributes & 0x10 != 0;
}

/// The body `print` and its three siblings share, reading the destination from
/// a dynamic binding.
fn print(
    argv: []repr.Value,
    newline: bool,
    name: [*:0]const u8,
    dflt_file: ?*FILE,
) raise.Error!repr.Value {
    const x = vm_state.dyn(name);
    return printImplX(argv, newline, dflt_file, 0, x);
}

/// Prints `argv[offset..]` to `x`, which may be a buffer, a function, a file,
/// or nil for the default handle.
///
/// An abstract that is not a file is silently ignored: it gives back nil
/// having printed nothing, which callers depend on, and is what stops the
/// `default` arm below from owning every non-file case.
fn printImplX(
    argv: []repr.Value,
    newline: bool,
    dflt_file: ?*FILE,
    offset: usize,
    x: repr.Value,
) raise.Error!repr.Value {
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

/// The body `printf` and its three siblings share.
fn printf(
    argv: []repr.Value,
    newline: bool,
    name: [*:0]const u8,
    dflt_file: ?*FILE,
) raise.Error!repr.Value {
    try args_core.arity(argv, 1, -1);
    const x = vm_state.dyn(name);
    return printfImplX(argv, newline, dflt_file, 0, x);
}

/// `printImplX` with a format string, and the same destinations.
fn printfImplX(
    argv: []repr.Value,
    newline: bool,
    dflt_file: ?*FILE,
    offset: usize,
    x: repr.Value,
) raise.Error!repr.Value {
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
            // `assertWriteable`, which would say "file is closed". Both
            // messages are ones a program reads, so the test stays separate.
            if (iofile.flags & file_closed != 0) return raise.panic("cannot print to closed file");
            try assertWriteable(iofile);
            f = streamOf(iofile);
        },
        else => return pp_format.panicf("cannot print to %v", .{x}),
    }
    // Not a `defer`: a conversion that raises inside `bufferFormat` returns
    // past the release below. Nothing leaks, because `buffers.new` gcallocs
    // and `gc/sweep.zig`'s `buffers.deinit` arm frees the backing store at the
    // next collection; the release here is what returns it sooner.
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

/// Reads up to `n_bytes_max` bytes onto the end of `buffer`.
///
/// A short read is not by itself a failure, since it is how the end of the
/// file is reached, so the error indicator decides.
///
/// The readability test is kept here as well as at `nfunFread`'s head, because
/// this is reachable from `io.zig`'s other readers and a check at one caller
/// is a check one caller can be added beside.
fn readChunk(iof: *File, buffer: *buffers.Buffer, n_bytes_max: usize) raise.Error!void {
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

/// The flag word a repeated mode flag reports, which is -1 beside
/// `mode_repeated`.
fn repeated(flags_out: *i32) i32 {
    flags_out.* = -1;
    return mode_repeated;
}

/// Closes the stream's descriptor across an exec. `c.fopen` has no standard
/// flag for that, so it is set separately.
fn setCloexecStream(file: ?*FILE) i32 {
    return std.c.fcntl(c.fileno(file), std.c.F.SETFD, fd_cloexec);
}

/// Stores a stream into a `File`, the inverse of `streamOf`.
inline fn setStreamOf(iof: *File, file: ?*FILE) void {
    iof.file = file;
}

/// Returns which standard output stream `file` is, or null when it is
/// neither.
fn standardOf(file: ?*FILE) ?Standard {
    if (file == stdoutFile()) return .out;
    if (file == stderrFile()) return .err;
    return null;
}

/// The standard error stream as this file's `FILE`.
fn stderrFile() ?*FILE {
    return stdio.err();
}

/// The standard input stream as this file's `FILE`, which is `host.FILE` under
/// another name. `stdio.zig` gives back the same type; these three exist so
/// that the registration rows below name one thing.
fn stdinFile() ?*FILE {
    return stdio.in();
}

/// The standard output stream as this file's `FILE`.
fn stdoutFile() ?*FILE {
    return stdio.out();
}

/// The stream a `File` stores.
///
/// A named accessor rather than the field, because this and `setStreamOf` are
/// the only places that spell the field: the abstract's payload is reached
/// through it at forty sites, and a change to how a stream is stored stops
/// here.
inline fn streamOf(iof: *File) ?*FILE {
    return iof.file;
}

/// The one path that has a stream as a bare pointer rather than as a `File`:
/// `file/open` has to `fstat` and possibly `c.fclose` its result before there
/// is a payload to put it in.
inline fn streamOfHandle(handle: *anyopaque) ?*FILE {
    return @ptrCast(handle);
}

// ==========================================================================
// Tests
// ==========================================================================

/// `scanMode` over a slice, which is what the tests below call.
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
    // scan asserts them before it reaches the repeated byte.
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

test "a mode gains the b it lacks and keeps the one it has" {
    var out: [mode_buf_len]u8 = undefined;
    try std.testing.expectEqualStrings("rb", std.mem.span(binaryMode("r", &out)));
    try std.testing.expectEqualStrings("wb", std.mem.span(binaryMode("w", &out)));
    try std.testing.expectEqualStrings("ab", std.mem.span(binaryMode("a", &out)));
    try std.testing.expectEqualStrings("r+b", std.mem.span(binaryMode("r+", &out)));
    try std.testing.expectEqualStrings("rnb", std.mem.span(binaryMode("rn", &out)));

    try std.testing.expectEqualStrings("rb", std.mem.span(binaryMode("rb", &out)));
    try std.testing.expectEqualStrings("wb+", std.mem.span(binaryMode("wb+", &out)));

    // Ten bytes is the most `scanMode` lets past its length check, so a copy
    // of ten plus the `b` and the terminator is what the buffer is sized for.
    try std.testing.expectEqualStrings("rbnnnnnnnn", std.mem.span(binaryMode("rbnnnnnnnn", &out)));
    try std.testing.expectEqualStrings("rnnnnnnnnnb", std.mem.span(binaryMode("rnnnnnnnnn", &out)));
}
