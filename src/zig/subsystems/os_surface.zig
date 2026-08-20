//! `os.c`'s cfunction surface: this file holds the platform, environment,
//! clock and miscellaneous cfunctions, and it assembles `janet_lib_os` out of
//! its own rows and the three other files of this object. This is Phase 10
//! Part 12.
//!
//! ## Why this is one selector and not eight
//!
//! `os.c` registers every `os/` binding from a single `janet_lib_os`, and its
//! cfunctions are `static`. Part 6's rule -- a cfunction surface goes to the
//! subsystem that already owns its data structure -- would put these forty-odd
//! functions into the eight `-Dos-*` selectors that hold their kernels, and it
//! cannot be applied here: the registration is indivisible, and a Zig table
//! cannot name a C static, so a build with `-Dos-fs=c` and `-Dos-process=zig`
//! would have no way to produce one `janet_lib_os`. Part 4's rule then decides
//! the rest from the other side -- a split is worth its seams only when the
//! pieces convert in *different* increments, and these convert in one because
//! they are registered in one.
//!
//! So `-Dos-surface` is a new selector and the count goes fifty-eight to
//! fifty-nine. The eight kernel selectors are untouched and still mean what
//! they meant: this object calls them across the C ABI exactly as `os.c` did.
//! `core` was not available as a suffix for the same reason Part 9 rejected
//! `-Dpeg-core`: in four other selectors it means "a kernel whose cfunction
//! surface is still in C", and this is the surface.
//!
//! ## Four files, one object
//!
//! `os_files.zig`, `os_calendar.zig` and `os_procs.zig` are separate sources
//! and separate modules, folded into one object on the shape `-Dpp`
//! established. Folding is what the single selector buys: `os_procs.zig` calls
//! `os_files.zig`'s permission parser as ordinary Zig, so a bad permission
//! argument propagates as a `raise.Error` instead of being delivered as a jump
//! through the spawn's frames.
//!
//! ## What is left in `os.c`
//!
//! One function, `janet_zig_os_stat_read`, and the reason is measured in
//! `os_files.zig`: musl declares `struct timespec` with a bitfield,
//! translate-c demotes any structure holding one to `opaque {}`, and `struct
//! stat` embeds three. Phase 10's decision 4 unparks the host structures and
//! this is the one it cannot reach.

const std = @import("std");
const builtin = @import("builtin");
const abi = @import("abi");
const oa = @import("os_abi");
const corefn = @import("corefn");
const raise = @import("raise");
const pp_format = @import("pp_format.zig");
const os_calendar = @import("os_calendar.zig");
const os_files = @import("os_files.zig");
const os_procs = @import("os_procs.zig");
const c = abi.c;
const stdio = @import("stdio.zig");
const lifecycle = @import("lifecycle.zig");
const arglayer = @import("arglayer.zig");
const io_core = @import("io_core.zig");
const containers = @import("containers.zig");
const h = oa.h;

const windows = builtin.os.tag == .windows;

const reduced_os = @hasDecl(c, "JANET_REDUCED_OS");
const no_processes = @hasDecl(c, "JANET_NO_PROCESSES");
const no_locales = @hasDecl(c, "JANET_NO_LOCALES");
const plan9 = false; // No Zig target; `os.c`'s Plan 9 arms are recorded, not written.
const has_ev = os_files.has_ev;

// ==========================================================================
// The kernels, and the rest of the C ABI
// ==========================================================================

extern fn janet_os_name() callconv(.c) [*:0]const u8;
extern fn janet_os_arch() callconv(.c) [*:0]const u8;
extern fn janet_os_compiler() callconv(.c) [*:0]const u8;
extern fn janet_os_cpu_count() callconv(.c) i32;

extern fn janet_os_environ_count(env: [*c][*c]u8) callconv(.c) i32;
extern fn janet_os_environ_separator(entry: [*:0]const u8) callconv(.c) i32;
extern fn janet_os_getenv(name: [*:0]const u8) callconv(.c) ?[*:0]const u8;
extern fn janet_os_setenv(name: [*:0]const u8, value: ?[*:0]const u8) callconv(.c) i32;

extern fn janet_os_time_now() callconv(.c) f64;
extern fn janet_os_sleep(seconds: f64) callconv(.c) void;

/// `src/core/util.h`. Reports the clock in parts, because `struct timespec`
/// cannot be named from Zig; `util.c` supplies it over either arm of
/// `-Dos-time`, and the note there says why.
extern fn janet_os_gettime(source: i32, sec: *i64, nsec: *i64) callconv(.c) i32;

extern fn janet_deinit() callconv(.c) void;
extern fn exit(status: c_int) callconv(.c) noreturn;
extern fn _Exit(status: c_int) callconv(.c) noreturn;
extern fn setlocale(category: c_int, locale: ?[*:0]const u8) callconv(.c) ?[*:0]const u8;
extern fn isatty(fd: c_int) callconv(.c) c_int;
extern fn _isatty(fd: c_int) callconv(.c) c_int;
extern fn fileno(f: ?*anyopaque) callconv(.c) c_int;
extern fn _fileno(f: ?*anyopaque) callconv(.c) c_int;
extern fn janet_strerror(e: c_int) callconv(.c) [*c]const u8;

/// `src/core/io.c`'s `stdout` handle. Part 11 records the three incompatible
/// shapes translate-c gives the macro across this project's targets, which is
/// why it is a function rather than a variable.

/// `janet_wrap_integer`, written out rather than called. `janet.h` declares the
/// function beside its macro and `wrap.c` defines it only for the two nanbox
/// layouts, so a tagged build has no such symbol and a Zig caller -- which
/// cannot use the macro -- does not link. `marsh.zig`, `pp_pretty.zig` and
/// `value_access.zig` write it out for the same reason, and `FOUND.md` has the
/// defect. This is the fourth subsystem to meet it.
inline fn wrapInteger(x: i32) c.Janet {
    return c.janet_wrap_number(@floatFromInt(x));
}

inline fn errno() c_int {
    return std.c._errno().*;
}

// ==========================================================================
// Platform introspection
// ==========================================================================

/// The `JANET_OS_NAME` and `JANET_ARCH_NAME` build overrides, stringified in
/// `state_abi.h` because they are bare tokens and translate-c surfaces a
/// macro's *value*. Where one is set it wins over the derived name, which is
/// what `os.c` does under `JANET_ZIG_OS_PLATFORM`.
const os_name_override: ?[:0]const u8 = if (@hasDecl(c, "JANET_ZIG_OS_NAME")) c.JANET_ZIG_OS_NAME else null;
const arch_name_override: ?[:0]const u8 = if (@hasDecl(c, "JANET_ZIG_ARCH_NAME")) c.JANET_ZIG_ARCH_NAME else null;

fn whichName() [*:0]const u8 {
    if (os_name_override) |name| return name.ptr;
    return janet_os_name();
}

fn whichImpl(argc: i32, argv: [*c]c.Janet) raise.Raising(c.Janet) {
    try arglayer.arity(argc, 0, 1);
    if (argc == 1 and c.janet_truthy(argv[0]) != 0) {
        _ = try arglayer.getKeyword(argv, 0); // Constrain to keywords.
        return c.janet_wrap_boolean(c.janet_equals(argv[0], c.janet_ckeywordv(whichName())));
    }
    return c.janet_ckeywordv(whichName());
}

fn archImpl(argc: i32, argv: [*c]c.Janet) raise.Raising(c.Janet) {
    _ = argv;
    try arglayer.fixarity(argc, 0);
    if (arch_name_override) |name| return c.janet_ckeywordv(name.ptr);
    return c.janet_ckeywordv(janet_os_arch());
}

fn compilerImpl(argc: i32, argv: [*c]c.Janet) raise.Raising(c.Janet) {
    _ = argv;
    try arglayer.fixarity(argc, 0);
    return c.janet_ckeywordv(janet_os_compiler());
}

fn exitImpl(argc: i32, argv: [*c]c.Janet) raise.Raising(c.Janet) {
    try arglayer.arity(argc, 0, 2);
    try lifecycle.sandboxAssert(c.JANET_SANDBOX_EXIT);
    var status: c_int = 0;
    if (argc == 0) {
        status = 0;
    } else if (c.janet_checkint(argv[0]) != 0) {
        status = c.janet_unwrap_integer(argv[0]);
    } else {
        // The docstring promises the hash of a non-integer; the C original
        // has always used EXIT_FAILURE instead. Reproduced.
        status = 1;
    }
    const force = argc >= 2 and c.janet_truthy(argv[1]) != 0;
    janet_deinit();
    if (force) _Exit(status);
    exit(status);
}

fn cpuCountImpl(argc: i32, argv: [*c]c.Janet) raise.Raising(c.Janet) {
    try arglayer.arity(argc, 0, 1);
    const count = janet_os_cpu_count();
    if (count < 0) return if (argc > 0) argv[0] else c.janet_wrap_nil();
    return wrapInteger(count);
}

/// The six locale categories `os/setlocale` names. `LC_*` are host constants,
/// so the keyword list is portable and the numbers come from `<locale.h>`.
const locale_categories = [_]struct { name: [:0]const u8, value: c_int }{
    .{ .name = "all", .value = h.LC_ALL },
    .{ .name = "collate", .value = h.LC_COLLATE },
    .{ .name = "ctype", .value = h.LC_CTYPE },
    .{ .name = "monetary", .value = h.LC_MONETARY },
    .{ .name = "numeric", .value = h.LC_NUMERIC },
    .{ .name = "time", .value = h.LC_TIME },
};

fn setlocaleImpl(argc: i32, argv: [*c]c.Janet) raise.Raising(c.Janet) {
    try arglayer.arity(argc, 0, 2);
    const locale_name = try arglayer.optCString(argv, argc, 0, null);
    var category: c_int = h.LC_ALL;
    if (argc > 1 and c.janet_checktype(argv[1], c.JANET_NIL) == 0) {
        category = for (locale_categories) |entry| {
            if (c.janet_keyeq(argv[1], entry.name.ptr) != 0) break entry.value;
        } else return pp_format.panicf(
            "expected one of :all, :collate, :ctype, :monetary, :numeric, or :time, got %v",
            .{argv[1]},
        );
    }
    const old = setlocale(category, @ptrCast(locale_name)) orelse return c.janet_wrap_nil();
    return c.janet_cstringv(old);
}

extern fn janet_cryptorand(out: [*]u8, n: usize) callconv(.c) c_int;

fn cryptorandImpl(argc: i32, argv: [*c]c.Janet) raise.Raising(c.Janet) {
    try arglayer.arity(argc, 1, 2);
    const n = try arglayer.getInteger(argv, 0);
    if (n < 0) return raise.panic("expected positive integer");
    var buffer: *c.JanetBuffer = undefined;
    var offset: i32 = 0;
    if (argc == 2) {
        buffer = try arglayer.getBuffer(argv, 1);
        offset = buffer.count;
    } else {
        buffer = c.janet_buffer(n);
    }
    try containers.bufferSetcount(buffer, offset + n);
    if (janet_cryptorand(buffer.data + @as(usize, @intCast(offset)), @intCast(n)) != 0) {
        return raise.panic("unable to get sufficient random data");
    }
    return c.janet_wrap_buffer(buffer);
}

extern fn janet_getfile(argv: [*c]const c.Janet, n: i32, flags: [*c]i32) callconv(.c) ?*anyopaque;

fn isattyImpl(argc: i32, argv: [*c]c.Janet) raise.Raising(c.Janet) {
    try arglayer.arity(argc, 0, 1);
    const f: ?*io_core.FILE = if (argc == 1)
        try io_core.janet_getfileImpl(argv, 0, null)
    else
        @ptrCast(@alignCast(stdio.out()));
    if (windows) {
        const fd = _fileno(f);
        if (fd == -1) return raise.panic("not a valid stream");
        return c.janet_wrap_boolean(_isatty(fd));
    }
    const fd = fileno(f);
    if (fd == -1) return raise.panic(@ptrCast(janet_strerror(errno())));
    return c.janet_wrap_boolean(isatty(fd));
}

// ==========================================================================
// The environment
//
// The lock is held across each of these, and it is a no-op in every build
// this tree can produce -- `os_abi.zig` has the reasoning. The *places* it is
// taken are the contract, and `os/getenv` in particular holds it across the
// copy of the borrowed `getenv` result rather than only across the call.
// ==========================================================================

fn environImpl(argc: i32, argv: [*c]c.Janet) raise.Raising(c.Janet) {
    _ = argv;
    try lifecycle.sandboxAssert(c.JANET_SANDBOX_ENV);
    try arglayer.fixarity(argc, 0);
    oa.lockEnviron();
    const env = oa.getEnviron();
    const nenv = janet_os_environ_count(env);
    const t = c.janet_table(nenv);
    var i: i32 = 0;
    while (i < nenv) : (i += 1) {
        const e: [*:0]const u8 = @ptrCast(env[@intCast(i)]);
        const separator = janet_os_environ_separator(e);
        if (separator < 0) {
            oa.unlockEnviron();
            return raise.panic("no '=' in environ");
        }
        const v: [*:0]const u8 = e + @as(usize, @intCast(separator)) + 1;
        c.janet_table_put(
            t,
            c.janet_stringv(e, separator),
            c.janet_stringv(v, @as(i32, @intCast(std.mem.len(v)))),
        );
    }
    oa.unlockEnviron();
    return c.janet_wrap_table(t);
}

fn getenvImpl(argc: i32, argv: [*c]c.Janet) raise.Raising(c.Janet) {
    try lifecycle.sandboxAssert(c.JANET_SANDBOX_ENV);
    try arglayer.arity(argc, 1, 2);
    const cstr = try arglayer.getCString(argv, 0);
    oa.lockEnviron();
    const res = janet_os_getenv(@ptrCast(cstr));
    const ret = if (res) |value|
        c.janet_cstringv(value)
    else if (argc == 2)
        argv[1]
    else
        c.janet_wrap_nil();
    oa.unlockEnviron();
    return ret;
}

/// `os/setenv` declares an arity of one to two and reads two arguments, so
/// `(os/setenv "K")` unsets. The result of the host call is discarded, exactly
/// as the C original discards it.
fn setenvImpl(argc: i32, argv: [*c]c.Janet) raise.Raising(c.Janet) {
    try lifecycle.sandboxAssert(c.JANET_SANDBOX_ENV);
    try arglayer.arity(argc, 1, 2);
    const ks = try arglayer.getCString(argv, 0);
    const vs = try arglayer.optCString(argv, argc, 1, null);
    oa.lockEnviron();
    _ = janet_os_setenv(@ptrCast(ks), @ptrCast(vs));
    oa.unlockEnviron();
    return c.janet_wrap_nil();
}

// ==========================================================================
// Clocks
// ==========================================================================

fn timeImpl(argc: i32, argv: [*c]c.Janet) raise.Raising(c.Janet) {
    _ = argv;
    try arglayer.fixarity(argc, 0);
    return c.janet_wrap_number(janet_os_time_now());
}

/// Mirrors `enum JanetTimeSource` in `src/core/util.h`, which `abi.zig`
/// deliberately does not translate. `os_time.zig` mirrors the same three
/// values for the same reason.
const clock_sources = [_]struct { name: [:0]const u8, value: i32 }{
    .{ .name = "realtime", .value = 0 },
    .{ .name = "monotonic", .value = 1 },
    .{ .name = "cputime", .value = 2 },
};

fn clockImpl(argc: i32, argv: [*c]c.Janet) raise.Raising(c.Janet) {
    try lifecycle.sandboxAssert(c.JANET_SANDBOX_HRTIME);
    try arglayer.arity(argc, 0, 2);

    const sourcestr = try arglayer.optKeyword(argv, argc, 0, null);
    var source: i32 = clock_sources[0].value;
    if (sourcestr != null) {
        source = for (clock_sources) |entry| {
            if (c.janet_cstrcmp(sourcestr, entry.name.ptr) == 0) break entry.value;
        } else return pp_format.panicf(
            "expected :realtime, :monotonic, or :cputime, got %v",
            .{argv[0]},
        );
    }

    var sec: i64 = undefined;
    var nsec: i64 = undefined;
    if (janet_os_gettime(source, &sec, &nsec) != 0) return raise.panic("could not get time");

    const formatstr = try arglayer.optKeyword(argv, argc, 1, null);
    if (formatstr == null or c.janet_cstrcmp(formatstr, "double") == 0) {
        const dtime = @as(f64, @floatFromInt(sec)) + (@as(f64, @floatFromInt(nsec)) / 1e9);
        return c.janet_wrap_number(dtime);
    } else if (c.janet_cstrcmp(formatstr, "int") == 0) {
        return c.janet_wrap_number(@floatFromInt(sec));
    } else if (c.janet_cstrcmp(formatstr, "tuple") == 0) {
        var tup = [2]c.Janet{
            c.janet_wrap_number(@floatFromInt(sec)),
            c.janet_wrap_number(@floatFromInt(nsec)),
        };
        return c.janet_wrap_tuple(c.janet_tuple_n(&tup, 2));
    }
    return pp_format.panicf("expected :double, :int, or :tuple, got %v", .{argv[1]});
}

fn sleepImpl(argc: i32, argv: [*c]c.Janet) raise.Raising(c.Janet) {
    try arglayer.fixarity(argc, 1);
    const delay = try arglayer.getNumber(argv, 0);
    if (delay < 0) return raise.panic("invalid argument to sleep");
    janet_os_sleep(delay);
    return c.janet_wrap_nil();
}

// ==========================================================================
// Registration
//
// The order is `janet_lib_os`'s, and it is preserved rather than tidied:
// `janet_nextmethod` walks a registration table linearly, so the order of the
// rows is observable. Part 7 found that the hard way in the parser.
// ==========================================================================

fn selfEntries() []const corefn.Entry {
    const list = comptime blk: {
        var acc: []const corefn.Entry = &.{};
        acc = acc ++ [_]corefn.Entry{
            corefn.reg("os/exit", &exitImpl, @src(), "(os/exit &opt x force)", "Exit from janet with an exit code equal to x. If x is not an integer, " ++
                "the exit with status equal the hash of x. If `force` is truthy will exit immediately and " ++
                "skip cleanup code."),
            corefn.reg("os/which", &whichImpl, @src(), "(os/which &opt test)", "Check the current operating system. If `test` is nil or unset, Returns one of:\n\n" ++
                "* :windows\n\n* :mingw\n\n* :cygwin\n\n* :macos\n\n" ++
                "* :web - Web assembly (emscripten)\n\n" ++
                "* :linux\n\n* :hurd\n\n* :freebsd\n\n* :openbsd\n\n* :netbsd\n\n" ++
                "* :dragonfly\n\n* :bsd\n\n" ++
                "* :posix - A POSIX compatible system (default)\n\n" ++
                "May also return a custom keyword specified at build time. Is `test` is truthy, will check if the current operating system equals `test` and return true if they are the same, false otherwise."),
            corefn.reg("os/arch", &archImpl, @src(), "(os/arch)", "Check the ISA that janet was compiled for. Returns one of:\n\n" ++
                "* :x86\n\n* :x64\n\n* :arm\n\n* :aarch64\n\n* :riscv32\n\n* :riscv64\n\n" ++
                "* :sparc\n\n* :wasm\n\n* :s390\n\n* :s390x\n\n* :unknown\n"),
            corefn.reg("os/compiler", &compilerImpl, @src(), "(os/compiler)", "Get the compiler used to compile the interpreter. Returns one of:\n\n" ++
                "* :gcc\n\n* :clang\n\n* :msvc\n\n* :kencc\n\n* :unknown\n\n"),
        };
        if (!reduced_os) {
            acc = acc ++ [_]corefn.Entry{
                corefn.reg("os/cpu-count", &cpuCountImpl, @src(), "(os/cpu-count &opt dflt)", "Get an approximate number of CPUs available on for this process to use. If " ++
                    "unable to get an approximation, will return a default value dflt."),
            };
        }
        break :blk acc[0..acc.len].*;
    };
    return &list;
}

/// The rows between `os/cpu-count` and the filesystem family, in
/// `janet_lib_os`'s order. `os/cwd`, `os/perm-string` and `os/perm-int` sit in
/// the middle of this run and are `os_files.zig`'s, which is why the table is
/// assembled from pieces rather than concatenated file by file.
fn miscEntries() []const corefn.Entry {
    const list = comptime blk: {
        var acc: []const corefn.Entry = &.{};
        acc = acc ++ [_]corefn.Entry{
            corefn.reg("os/cryptorand", &cryptorandImpl, @src(), "(os/cryptorand n &opt buf)", "Get or append `n` bytes of good quality random data provided by the OS. Returns a new buffer or `buf`."),
        };
        break :blk acc[0..acc.len].*;
    };
    return &list;
}

fn clockEntries() []const corefn.Entry {
    const list = comptime blk: {
        var acc: []const corefn.Entry = &.{};
        acc = acc ++ [_]corefn.Entry{
            corefn.reg("os/time", &timeImpl, @src(), "(os/time)", "Get the current time expressed as the number of whole seconds since " ++
                "January 1, 1970, the Unix epoch. Returns a real number."),
        };
        break :blk acc[0..acc.len].*;
    };
    return &list;
}

fn tailEntries() []const corefn.Entry {
    const list = comptime blk: {
        var acc: []const corefn.Entry = &.{};
        acc = acc ++ [_]corefn.Entry{
            corefn.reg("os/sleep", &sleepImpl, @src(), "(os/sleep n)", "Suspend the program for `n` seconds. `n` can be a real number. Returns " ++
                "nil."),
            corefn.reg("os/isatty", &isattyImpl, @src(), "(os/isatty &opt file)", "Returns true if `file` is a terminal. If `file` is not specified, " ++
                "it will default to standard output."),
        };
        if (!no_locales) acc = acc ++ [_]corefn.Entry{
            corefn.reg("os/setlocale", &setlocaleImpl, @src(), "(os/setlocale &opt locale category)", "Set the system locale, which affects how dates and numbers are formatted. " ++
                "Passing nil to locale will return the current locale. Category can be one of:\n\n" ++
                " * :all (default)\n * :collate\n * :ctype\n * :monetary\n * :numeric\n * :time\n\n" ++
                "Returns the new locale if set successfully, otherwise nil. Note that this will affect " ++
                "other functions such as `os/strftime` and even `printf`."),
        };
        if (!plan9) acc = acc ++ [_]corefn.Entry{
            corefn.reg("os/environ", &environImpl, @src(), "(os/environ)", "Get a copy of the OS environment table."),
        };
        acc = acc ++ [_]corefn.Entry{
            corefn.reg("os/getenv", &getenvImpl, @src(), "(os/getenv variable &opt dflt)", "Get the string value of an environment variable."),
            corefn.reg("os/setenv", &setenvImpl, @src(), "(os/setenv variable value)", "Set an environment variable."),
        };
        break :blk acc[0..acc.len].*;
    };
    return &list;
}

fn hrtimeEntries() []const corefn.Entry {
    const list = comptime [_]corefn.Entry{
        corefn.reg("os/clock", &clockImpl, @src(), "(os/clock &opt source format)", "Return the current time of the requested clock source.\n\n" ++
            "The `source` argument selects the clock source to use, when not specified the default " ++
            "is `:realtime`:\n" ++
            "- :realtime: Return the real (i.e., wall-clock) time. This clock is affected by discontinuous " ++
            "  jumps in the system time\n" ++
            "- :monotonic: Return the number of whole + fractional seconds since some fixed point in " ++
            "  time. The clock is guaranteed to be non-decreasing in real time.\n" ++
            "- :cputime: Return the CPU time consumed by this process  (i.e. all threads in the process)\n" ++
            "The `format` argument selects the type of output, when not specified the default is `:double`:\n" ++
            "- :double: Return the number of seconds + fractional seconds as a double\n" ++
            "- :int: Return the number of seconds as an integer\n" ++
            "- :tuple: Return a 2 integer tuple [seconds, nanoseconds]\n"),
    };
    return &list;
}

pub fn janet_lib_osImpl(env: *c.JanetTable) raise.Raising(void) {
    // `janet_lib_os` opens with a Windows critical-section initialisation
    // guarded by `JANET_THREADS`, which `FOUND.md` records is defined nowhere
    // in this tree. It is recorded here rather than written, on Part 8's rule
    // about a branch no configuration compiles.
    var table: [512]corefn.Entry = undefined;
    var n: usize = 0;
    const push = struct {
        fn f(dest: []corefn.Entry, count: *usize, rows: []const corefn.Entry) void {
            @memcpy(dest[count.* .. count.* + rows.len], rows);
            count.* += rows.len;
        }
    }.f;

    push(&table, &n, selfEntries());
    if (!reduced_os) {
        // Un-sandboxed miscellany, then the filesystem, then processes, then
        // the high-resolution clock -- `janet_lib_os`'s own order.
        push(&table, &n, os_files.entries()[0..1]); // os/cwd
        push(&table, &n, miscEntries());
        push(&table, &n, os_files.entries()[1..3]); // os/perm-string, os/perm-int
        push(&table, &n, os_calendar.entries()[0..1]); // os/mktime
        push(&table, &n, clockEntries());
        push(&table, &n, os_calendar.entries()[1..]); // os/date, os/strftime
        push(&table, &n, tailEntries());
        push(&table, &n, os_files.entries()[3..]);
        if (!no_processes) push(&table, &n, os_procs.entries());
        push(&table, &n, hrtimeEntries());
        if (has_ev) {
            push(&table, &n, os_files.evEntries());
            push(&table, &n, os_procs.evEntries());
        }
    }
    table[n] = corefn.end;
    corefn.install(env, table[0 .. n + 1]);
}

export fn janet_lib_os(env: *c.JanetTable) callconv(.c) void {
    raise.reported(janet_lib_osImpl(env));
}
