//! The `os/` module: what the host is, what time it is, and what the
//! environment holds.
//!
//! Four files once -- the cfunctions in one, and the time, platform and
//! environment kernels behind the C-ABI seam it reached them through. They
//! have one name because Janet publishes one: `os`. The pieces that keep names
//! of their own are beside this file in `os/`.
//!
//! Seven `extern fn` here were `export fn` there. One file cannot hold both,
//! so the merge converted them; they are ordinary Zig calls.
//!
//! **The `@export`s kept their gates, and that is the point.** The four sources
//! did not share one: `os_platform` and `os_surface` were unconditional,
//! `os_environ` was `!reduced_os`, and `os_time` was `hasGettime`. Collapsing
//! all four to one gate would have been the easy merge and it would have
//! given `-Dreduced-os=true` seven exported symbols it does not have today --
//! **a change to a configuration's export surface, made silently by a file
//! move.** The bodies are compiled unconditionally now, which is harmless
//! because none of them reads its own gate and `os_surface` guards
//! *registration* rather than compilation; the symbols stay conditional, so
//! every configuration exports exactly what it exported before.

const options = @import("options");
const std = @import("std");
const builtin = @import("builtin");
const oa = @import("os/abi.zig");
const corefn = @import("corefn");
const raise = @import("raise");
const pp_format = @import("pp/format.zig");
const os_calendar = @import("os/date.zig");
const os_files = @import("os/fs.zig");
const os_procs = @import("os/process.zig");
const types = @import("types");
const repr = @import("repr");
const c = @import("cabi");
const stdio = @import("stdio.zig");
const vm_lifecycle = @import("vm/lifecycle.zig");
const io_core = @import("io.zig");
const config = @import("config");
const tables = @import("value/tables.zig");
const tuples = @import("value/tuples.zig");
const utils = @import("utils.zig");
const order = @import("value/helpers/order.zig");
const wrap = @import("value/helpers/wrap.zig");
const args_core = @import("args.zig");
const buffers = @import("value/buffers.zig");
const value = @import("value.zig");

// -------------------------------------------------------------------------
// The cfunctions -- what `os_surface.zig` was.
// -------------------------------------------------------------------------
const h = oa.h;

const windows = builtin.os.tag == .windows;

const reduced_os = config.reduced_os;
const no_processes = !config.processes;
const no_locales = !config.locales;
const plan9 = false; // No Zig target; `os.c`'s Plan 9 arms are recorded, not written.
const has_ev = os_files.has_ev;

// ==========================================================================
// The kernels, and the rest of the C ABI
// ==========================================================================

/// `src/core/util.h`. Reports the clock in parts, because `struct timespec`
/// cannot be named from Zig; `util.c` supplies it over either arm of
/// `-Dos-time`, and the note there says why.
extern fn exit(status: c_int) callconv(.c) noreturn;
extern fn _Exit(status: c_int) callconv(.c) noreturn;
extern fn setlocale(category: c_int, locale: ?[*:0]const u8) callconv(.c) ?[*:0]const u8;
extern fn isatty(fd: c_int) callconv(.c) c_int;
extern fn _isatty(fd: c_int) callconv(.c) c_int;
extern fn fileno(f: ?*anyopaque) callconv(.c) c_int;
extern fn _fileno(f: ?*anyopaque) callconv(.c) c_int;

/// The `stdout` handle. It is a function rather than a variable because the
/// macro has three incompatible shapes across this project's targets.
/// `janet_wrap_integer`, written out rather than called. Janet declares the
/// function beside its macro and defines it only for the two nanbox layouts,
/// so a tagged build has no such symbol and a Zig caller -- which cannot use
/// the macro -- does not link. `marsh.zig`, `pp/pretty.zig` and
/// `value/helpers/access.zig` write it out for the same reason, and `FOUND.md`
/// has the defect.
inline fn wrapInteger(x: i32) repr.Value {
    return wrap.fromNumber(@floatFromInt(x));
}

inline fn errno() c_int {
    return std.c._errno().*;
}

// ==========================================================================
// Platform introspection
// ==========================================================================

/// The `JANET_OS_NAME` and `JANET_ARCH_NAME` build overrides. Janet spells
/// them as bare tokens and stringifies them at the use; `config` carries them
/// as strings already. Where one is set it wins over the derived name, which
/// is what `os.c` does under `JANET_ZIG_OS_PLATFORM`.
const os_name_override: ?[:0]const u8 = if (config.os_name) |n| n ++ "" else null;
const arch_name_override: ?[:0]const u8 = if (config.arch_name) |n| n ++ "" else null;

fn whichName() [*:0]const u8 {
    if (os_name_override) |name| return name.ptr;
    return osName();
}

fn cfunWhich(argv: []repr.Value) raise.Raising(repr.Value) {
    try args_core.arity(argv, 0, 1);
    if (@as(i32, @intCast(argv.len)) == 1 and repr.truthy(argv[0])) {
        _ = try args_core.getKeyword(argv, 0); // Constrain to keywords.
        return wrap.fromBoolean(order.equals(argv[0], value.fromBytes(std.mem.span(whichName()), .keyword)) != 0);
    }
    return value.fromBytes(std.mem.span(whichName()), .keyword);
}

fn cfunArch(argv: []repr.Value) raise.Raising(repr.Value) {
    try args_core.fixarity(argv, 0);
    if (arch_name_override) |name| return value.fromBytes(name, .keyword);
    return value.fromBytes(std.mem.span(osArch()), .keyword);
}

fn cfunCompiler(argv: []repr.Value) raise.Raising(repr.Value) {
    try args_core.fixarity(argv, 0);
    return value.fromBytes(std.mem.span(osCompiler()), .keyword);
}

fn cfunExit(argv: []repr.Value) raise.Raising(repr.Value) {
    try args_core.arity(argv, 0, 2);
    try vm_lifecycle.sandboxAssert(types.Sandbox.of(&.{"exit"}));
    var status: c_int = 0;
    if (@as(i32, @intCast(argv.len)) == 0) {
        status = 0;
    } else if (args_core.checkint(argv[0]) != 0) {
        status = wrap.toInteger(argv[0]);
    } else {
        // The docstring promises the hash of a non-integer; the C original
        // has always used EXIT_FAILURE instead. Reproduced.
        status = 1;
    }
    const force = @as(i32, @intCast(argv.len)) >= 2 and repr.truthy(argv[1]);
    vm_lifecycle.deinitAbi();
    if (force) _Exit(status);
    exit(status);
}

fn cfunCpuCount(argv: []repr.Value) raise.Raising(repr.Value) {
    try args_core.arity(argv, 0, 1);
    const count = osCpuCount();
    if (count < 0) return if (@as(i32, @intCast(argv.len)) > 0) argv[0] else wrap.fromNil();
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

fn cfunSetlocale(argv: []repr.Value) raise.Raising(repr.Value) {
    try args_core.arity(argv, 0, 2);
    const locale_name = try args_core.optCString(argv, 0, null);
    var category: c_int = h.LC_ALL;
    if (@as(i32, @intCast(argv.len)) > 1 and !repr.checkType(argv[1], repr.Tag.nil)) {
        category = for (locale_categories) |entry| {
            if (args_core.keyeq(argv[1], entry.name.ptr) != 0) break entry.value;
        } else return pp_format.panicf(
            "expected one of :all, :collate, :ctype, :monetary, :numeric, or :time, got %v",
            .{argv[1]},
        );
    }
    const old = setlocale(category, @ptrCast(locale_name)) orelse return wrap.fromNil();
    return value.fromBytes(std.mem.span(old), .string);
}

fn cfunCryptorand(argv: []repr.Value) raise.Raising(repr.Value) {
    try args_core.arity(argv, 1, 2);
    const n = try args_core.getInteger(argv, 0);
    if (n < 0) return raise.panic("expected positive integer");
    var buffer: *types.JanetBuffer = undefined;
    var offset: i32 = 0;
    if (@as(i32, @intCast(argv.len)) == 2) {
        buffer = try args_core.getBuffer(argv, 1);
        offset = buffer.count;
    } else {
        buffer = buffers.new(n);
    }
    try buffers.setcount(buffer, offset + n);
    if (utils.cryptorand(buffer.data.? + @as(usize, @intCast(offset)), @intCast(n)) != 0) {
        return raise.panic("unable to get sufficient random data");
    }
    return wrap.fromBuffer(buffer);
}

fn cfunIsatty(argv: []repr.Value) raise.Raising(repr.Value) {
    try args_core.arity(argv, 0, 1);
    const f: ?*io_core.FILE = if (@as(i32, @intCast(argv.len)) == 1)
        try io_core.getfile(argv, 0, null)
    else
        @ptrCast(@alignCast(stdio.out()));
    if (windows) {
        const fd = _fileno(f);
        if (fd == -1) return raise.panic("not a valid stream");
        return wrap.fromBoolean(_isatty(fd) != 0);
    }
    const fd = fileno(f);
    if (fd == -1) return raise.panic(@ptrCast(utils.strerrorSafe(errno())));
    return wrap.fromBoolean(isatty(fd) != 0);
}

// ==========================================================================
// The environment
//
// The lock is held across each of these, and it is a no-op in every build
// this tree can produce -- `os/abi.zig` has the reasoning. The *places* it is
// taken are the contract, and `os/getenv` in particular holds it across the
// copy of the borrowed `getenv` result rather than only across the call.
// ==========================================================================

fn cfunEnviron(argv: []repr.Value) raise.Raising(repr.Value) {
    try vm_lifecycle.sandboxAssert(types.Sandbox.of(&.{"env"}));
    try args_core.fixarity(argv, 0);
    oa.lockEnviron();
    const env = oa.getEnviron();
    const nenv = environCount(env);
    const t = tables.new(nenv);
    var i: i32 = 0;
    while (i < nenv) : (i += 1) {
        const e: [*:0]const u8 = @ptrCast(env.?[@intCast(i)]);
        const separator = environSeparator(e);
        if (separator < 0) {
            oa.unlockEnviron();
            return raise.panic("no '=' in environ");
        }
        const v: [*:0]const u8 = e + @as(usize, @intCast(separator)) + 1;
        tables.put(
            t,
            value.fromBytes(e[0..@intCast(separator)], .string),
            value.fromBytes(std.mem.span(v), .string),
        );
    }
    oa.unlockEnviron();
    return wrap.fromTable(t);
}

fn cfunGetenv(argv: []repr.Value) raise.Raising(repr.Value) {
    try vm_lifecycle.sandboxAssert(types.Sandbox.of(&.{"env"}));
    try args_core.arity(argv, 1, 2);
    const cstr = try args_core.getCString(argv, 0);
    oa.lockEnviron();
    const res = environGet(@ptrCast(cstr));
    const ret = if (res) |val|
        value.fromBytes(std.mem.span(val), .string)
    else if (@as(i32, @intCast(argv.len)) == 2)
        argv[1]
    else
        wrap.fromNil();
    oa.unlockEnviron();
    return ret;
}

/// `os/setenv` declares an arity of one to two and reads two arguments, so
/// `(os/setenv "K")` unsets. The result of the host call is discarded, exactly
/// as the C original discards it.
fn cfunSetenv(argv: []repr.Value) raise.Raising(repr.Value) {
    try vm_lifecycle.sandboxAssert(types.Sandbox.of(&.{"env"}));
    try args_core.arity(argv, 1, 2);
    const ks = try args_core.getCString(argv, 0);
    const vs = try args_core.optCString(argv, 1, null);
    oa.lockEnviron();
    _ = environSet(@ptrCast(ks), @ptrCast(vs));
    oa.unlockEnviron();
    return wrap.fromNil();
}

// ==========================================================================
// Clocks
// ==========================================================================

fn cfunTime(argv: []repr.Value) raise.Raising(repr.Value) {
    try args_core.fixarity(argv, 0);
    return wrap.fromNumber(timeNow());
}

/// Mirrors `enum JanetTimeSource` in `src/core/util.h`, which no translation
/// ever carried. `os_time.zig` mirrors the same three values for the same
/// reason.
const clock_sources = [_]struct { name: [:0]const u8, value: i32 }{
    .{ .name = "realtime", .value = 0 },
    .{ .name = "monotonic", .value = 1 },
    .{ .name = "cputime", .value = 2 },
};

fn cfunClock(argv: []repr.Value) raise.Raising(repr.Value) {
    try vm_lifecycle.sandboxAssert(types.Sandbox.of(&.{"hrtime"}));
    try args_core.arity(argv, 0, 2);

    const sourcestr = try args_core.optKeyword(argv, 0, null);
    var source: i32 = clock_sources[0].value;
    if (sourcestr != null) {
        source = for (clock_sources) |entry| {
            if (utils.cstrcmp(sourcestr.?, entry.name.ptr) == 0) break entry.value;
        } else return pp_format.panicf(
            "expected :realtime, :monotonic, or :cputime, got %v",
            .{argv[0]},
        );
    }

    var sec: i64 = undefined;
    var nsec: i64 = undefined;
    if (gettime(source, &sec, &nsec) != 0) return raise.panic("could not get time");

    const formatstr = try args_core.optKeyword(argv, 1, null);
    if (formatstr == null or utils.cstrcmp(formatstr.?, "double") == 0) {
        const dtime = @as(f64, @floatFromInt(sec)) + (@as(f64, @floatFromInt(nsec)) / 1e9);
        return wrap.fromNumber(dtime);
    } else if (utils.cstrcmp(formatstr.?, "int") == 0) {
        return wrap.fromNumber(@floatFromInt(sec));
    } else if (utils.cstrcmp(formatstr.?, "tuple") == 0) {
        var tup = [2]repr.Value{
            wrap.fromNumber(@floatFromInt(sec)),
            wrap.fromNumber(@floatFromInt(nsec)),
        };
        return wrap.fromTuple(tuples.newFrom(&tup));
    }
    return pp_format.panicf("expected :double, :int, or :tuple, got %v", .{argv[1]});
}

fn cfunSleep(argv: []repr.Value) raise.Raising(repr.Value) {
    try args_core.fixarity(argv, 1);
    const delay = try args_core.getNumber(argv, 0);
    if (delay < 0) return raise.panic("invalid argument to sleep");
    sleepFor(delay);
    return wrap.fromNil();
}

// ==========================================================================
// Registration
//
// The order is `janet_lib_os`'s, and it is preserved rather than tidied:
// `janet_nextmethod` walks a registration table linearly, so the order of the
// rows is observable.
// ==========================================================================

fn selfEntries() []const corefn.Entry {
    const list = comptime blk: {
        var acc: []const corefn.Entry = &.{};
        acc = acc ++ [_]corefn.Entry{
            corefn.reg("os/exit", &cfunExit, @src(), "(os/exit &opt x force)", "Exit from janet with an exit code equal to x. If x is not an integer, " ++
                "the exit with status equal the hash of x. If `force` is truthy will exit immediately and " ++
                "skip cleanup code."),
            corefn.reg("os/which", &cfunWhich, @src(), "(os/which &opt test)", "Check the current operating system. If `test` is nil or unset, Returns one of:\n\n" ++
                "* :windows\n\n* :mingw\n\n* :cygwin\n\n* :macos\n\n" ++
                "* :web - Web assembly (emscripten)\n\n" ++
                "* :linux\n\n* :hurd\n\n* :freebsd\n\n* :openbsd\n\n* :netbsd\n\n" ++
                "* :dragonfly\n\n* :bsd\n\n" ++
                "* :posix - A POSIX compatible system (default)\n\n" ++
                "May also return a custom keyword specified at build time. Is `test` is truthy, will check if the current operating system equals `test` and return true if they are the same, false otherwise."),
            corefn.reg("os/arch", &cfunArch, @src(), "(os/arch)", "Check the ISA that janet was compiled for. Returns one of:\n\n" ++
                "* :x86\n\n* :x64\n\n* :arm\n\n* :aarch64\n\n* :riscv32\n\n* :riscv64\n\n" ++
                "* :sparc\n\n* :wasm\n\n* :s390\n\n* :s390x\n\n* :unknown\n"),
            corefn.reg("os/compiler", &cfunCompiler, @src(), "(os/compiler)", "Get the compiler used to compile the interpreter. Returns one of:\n\n" ++
                "* :gcc\n\n* :clang\n\n* :msvc\n\n* :kencc\n\n* :unknown\n\n"),
        };
        if (!reduced_os) {
            acc = acc ++ [_]corefn.Entry{
                corefn.reg("os/cpu-count", &cfunCpuCount, @src(), "(os/cpu-count &opt dflt)", "Get an approximate number of CPUs available on for this process to use. If " ++
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
            corefn.reg("os/cryptorand", &cfunCryptorand, @src(), "(os/cryptorand n &opt buf)", "Get or append `n` bytes of good quality random data provided by the OS. Returns a new buffer or `buf`."),
        };
        break :blk acc[0..acc.len].*;
    };
    return &list;
}

fn clockEntries() []const corefn.Entry {
    const list = comptime blk: {
        var acc: []const corefn.Entry = &.{};
        acc = acc ++ [_]corefn.Entry{
            corefn.reg("os/time", &cfunTime, @src(), "(os/time)", "Get the current time expressed as the number of whole seconds since " ++
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
            corefn.reg("os/sleep", &cfunSleep, @src(), "(os/sleep n)", "Suspend the program for `n` seconds. `n` can be a real number. Returns " ++
                "nil."),
            corefn.reg("os/isatty", &cfunIsatty, @src(), "(os/isatty &opt file)", "Returns true if `file` is a terminal. If `file` is not specified, " ++
                "it will default to standard output."),
        };
        if (!no_locales) acc = acc ++ [_]corefn.Entry{
            corefn.reg("os/setlocale", &cfunSetlocale, @src(), "(os/setlocale &opt locale category)", "Set the system locale, which affects how dates and numbers are formatted. " ++
                "Passing nil to locale will return the current locale. Category can be one of:\n\n" ++
                " * :all (default)\n * :collate\n * :ctype\n * :monetary\n * :numeric\n * :time\n\n" ++
                "Returns the new locale if set successfully, otherwise nil. Note that this will affect " ++
                "other functions such as `os/strftime` and even `printf`."),
        };
        if (!plan9) acc = acc ++ [_]corefn.Entry{
            corefn.reg("os/environ", &cfunEnviron, @src(), "(os/environ)", "Get a copy of the OS environment table."),
        };
        acc = acc ++ [_]corefn.Entry{
            corefn.reg("os/getenv", &cfunGetenv, @src(), "(os/getenv variable &opt dflt)", "Get the string value of an environment variable."),
            corefn.reg("os/setenv", &cfunSetenv, @src(), "(os/setenv variable value)", "Set an environment variable."),
        };
        break :blk acc[0..acc.len].*;
    };
    return &list;
}

fn hrtimeEntries() []const corefn.Entry {
    const list = comptime [_]corefn.Entry{
        corefn.reg("os/clock", &cfunClock, @src(), "(os/clock &opt source format)", "Return the current time of the requested clock source.\n\n" ++
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

pub fn libOs(env: *types.JanetTable) raise.Raising(void) {
    // `janet_lib_os` opens with a Windows critical-section initialisation
    // guarded by `JANET_THREADS`, which `FOUND.md` records is defined nowhere
    // in this tree. It is recorded here rather than written: a branch no
    // configuration compiles is a branch nothing checks.
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
    corefn.installTerminated(env, &table);
}

pub fn libOsAbi(env: *types.JanetTable) void {
    raise.reported(libOs(env));
}

// -------------------------------------------------------------------------
// Time -- what `os_time.zig` was.
// -------------------------------------------------------------------------

/// Mirrors `enum JanetTimeSource` in `src/core/util.h`.
const source_realtime: i32 = 0;
const source_monotonic: i32 = 1;
const source_cputime: i32 = 2;

/// Windows file times count 100-nanosecond intervals from January 1, 1601.
const windows_epoch_offset: i64 = 116444736000000000;
const hundred_ns_per_second: i64 = 10000000;

const FILETIME = extern struct {
    low: u32,
    high: u32,
};

extern "kernel32" fn GetSystemTimeAsFileTime(*FILETIME) callconv(.winapi) void;
extern "kernel32" fn QueryPerformanceCounter(*i64) callconv(.winapi) c_int;
extern "kernel32" fn QueryPerformanceFrequency(*i64) callconv(.winapi) c_int;
extern "kernel32" fn GetCurrentProcess() callconv(.winapi) ?*anyopaque;
extern "kernel32" fn GetProcessTimes(?*anyopaque, *FILETIME, *FILETIME, *FILETIME, *FILETIME) callconv(.winapi) c_int;
extern "kernel32" fn Sleep(u32) callconv(.winapi) void;

extern fn time(?*TimeT) callconv(.c) TimeT;

const TimeT = if (windows) i64 else std.c.time_t;

fn fileTimeToInt(ft: FILETIME) i64 {
    return @as(i64, ft.low) | (@as(i64, ft.high) << 32);
}

/// Read a clock source, reporting seconds and nanoseconds separately.
///
/// Returns 0 on success and -1 on failure, matching the C shim. An unrecognized
/// source falls back to the real-time clock, as the C implementation's
/// initialized-then-overwritten clock id does.
pub fn gettime(source: i32, sec_out: *i64, nsec_out: *i64) i32 {
    if (windows) {
        switch (source) {
            source_monotonic => {
                var count: i64 = undefined;
                var frequency: i64 = undefined;
                _ = QueryPerformanceCounter(&count);
                _ = QueryPerformanceFrequency(&frequency);
                sec_out.* = @divTrunc(count, frequency);
                const remainder = @rem(count, frequency);
                nsec_out.* = @divTrunc(remainder * 1000000000, frequency);
            },
            source_cputime => {
                var creation: FILETIME = undefined;
                var exit_time: FILETIME = undefined;
                var kernel: FILETIME = undefined;
                var user: FILETIME = undefined;
                _ = GetProcessTimes(GetCurrentProcess(), &creation, &exit_time, &kernel, &user);
                const ticks = fileTimeToInt(user);
                sec_out.* = @divTrunc(ticks, hundred_ns_per_second);
                nsec_out.* = @rem(ticks, hundred_ns_per_second) * 100;
            },
            else => {
                var ft: FILETIME = undefined;
                GetSystemTimeAsFileTime(&ft);
                const ticks = fileTimeToInt(ft) - windows_epoch_offset;
                sec_out.* = @divTrunc(ticks, hundred_ns_per_second);
                nsec_out.* = @rem(ticks, hundred_ns_per_second) * 100;
            },
        }
        return 0;
    }

    const clock_id: std.c.clockid_t = switch (source) {
        source_monotonic => .MONOTONIC,
        source_cputime => .PROCESS_CPUTIME_ID,
        else => .REALTIME,
    };
    var spec: std.c.timespec = undefined;
    if (std.c.clock_gettime(clock_id, &spec) != 0) return -1;
    sec_out.* = @intCast(spec.sec);
    nsec_out.* = @intCast(spec.nsec);
    return 0;
}

/// Whole seconds since the Unix epoch, as `os/time` reports them.
pub fn timeNow() f64 {
    return @floatFromInt(time(null));
}

/// Suspend the caller for `seconds`, which C has already checked is not
/// negative.
///
/// Janet zeroes the fractional part above `UINT32_MAX` seconds, because the
/// subtraction it uses to isolate that part goes through a `uint32_t`; that is
/// preserved. Converting the whole-second part of a very large delay is
/// undefined in C, so this saturates instead. Both cases are far longer than
/// any process runs.
pub fn sleepFor(seconds: f64) void {
    if (windows) {
        Sleep(saturatingCast(u32, seconds * 1000));
        return;
    }

    const whole = saturatingCast(i64, seconds);
    const fraction = if (seconds <= @as(f64, std.math.maxInt(u32)))
        (seconds - @as(f64, @floatFromInt(@as(u32, @intFromFloat(seconds))))) * 1000000000
    else
        0;
    var spec: std.c.timespec = .{
        .sec = @intCast(whole),
        .nsec = @intFromFloat(fraction),
    };
    while (true) {
        const rc = std.c.nanosleep(&spec, &spec);
        if (rc == 0) return;
        if (std.c._errno().* != @intFromEnum(std.c.E.INTR)) return;
    }
}

/// Convert toward zero, clamping instead of trapping. This reproduces the
/// AArch64 conversion the C implementation performs without a sanitizer: a NaN
/// becomes zero and an out-of-range value becomes the nearest bound. A NaN is
/// separated first because `@intFromFloat` is illegal for it and because the
/// ordinary comparisons below would otherwise send it to the low bound.
fn saturatingCast(comptime T: type, x: f64) T {
    if (std.math.isNan(x)) return 0;
    const low: f64 = @floatFromInt(@as(T, std.math.minInt(T)));
    const high: f64 = @floatFromInt(@as(T, std.math.maxInt(T)));
    if (!(x > low)) return std.math.minInt(T);
    if (x >= high) return std.math.maxInt(T);
    return @intFromFloat(x);
}

test "saturating conversion clamps rather than trapping" {
    try std.testing.expectEqual(@as(u32, 0), saturatingCast(u32, -1.0));
    try std.testing.expectEqual(@as(i64, 0), saturatingCast(i64, std.math.nan(f64)));
    try std.testing.expectEqual(@as(u32, 5), saturatingCast(u32, 5.9));
    try std.testing.expectEqual(@as(u32, std.math.maxInt(u32)), saturatingCast(u32, 1e30));
    try std.testing.expectEqual(@as(i64, std.math.maxInt(i64)), saturatingCast(i64, 1e300));
}

/// The host's `struct timespec`.
///
/// `std.c.timespec` everywhere it is a real declaration, which is every POSIX
/// target and is the type `gettime` above already hands to
/// `clock_gettime` -- so using it here adds no exposure that this file did not
/// already have. **Windows is not one of those targets**: `std.c.time_t` is
/// `void` there, because Zig's `std.c` describes a libc Windows does not have,
/// and the field types therefore do not exist. mingw-w64's own declaration is
/// `{ __int64 tv_sec; long tv_nsec; }`, with `long` 32 bits, and that is what
/// the Windows arm spells out.
///
/// The `x86_64-windows-gnu` cross-compile is what found this, by failing with
/// `expected integer or vector, found 'void'`: an arm this host does not
/// select is not merely unreachable but unchecked.
pub const Timespec = if (windows) extern struct {
    sec: i64,
    nsec: c_long,
} else std.c.timespec;

/// `janet_gettime`, the `struct timespec` abi over `gettime` above.
///
/// The Zig kernel reports seconds and nanoseconds separately, and something
/// has to put them into a `timespec`.
///
/// A comment here once said `struct timespec` "cannot be named from Zig", and
/// that is true of a *translated* one -- musl declares its padding as a
/// bitfield and `translate-c` demotes any structure with one to an opaque
/// type. It is not true of `std.c.timespec`, which is Zig's own declaration of
/// the same layout and which this file already uses for `clock_gettime` and
/// `nanosleep`.
///
/// `enum JanetTimeSource` is passed as `c_uint`, which is what clang gives an
/// enumeration whose enumerators are all non-negative. `test/os_time.zig` calls
/// this with the enum directly, including a value outside it, so the width is
/// checked rather than assumed.
///
/// Nothing in the runtime calls it -- every Zig caller uses `gettime` and takes
/// the parts. It is kept because it is a published symbol.
pub fn gettimeAbi(spec: *Timespec, source: c_uint) c_int {
    var sec: i64 = undefined;
    var nsec: i64 = undefined;
    if (gettime(@bitCast(source), &sec, &nsec) != 0) return -1;
    spec.sec = @intCast(sec);
    spec.nsec = @intCast(nsec);
    return 0;
}

// -------------------------------------------------------------------------
// Platform identity -- what `os_platform.zig` was.
// -------------------------------------------------------------------------

const os_name = switch (builtin.os.tag) {
    .windows => switch (builtin.abi) {
        .gnu => "mingw",
        else => "windows",
    },
    .macos, .ios, .tvos, .watchos, .visionos => "macos",
    .emscripten => "web",
    .linux => "linux",
    .hurd => "hurd",
    .freebsd => "freebsd",
    .netbsd => "netbsd",
    .openbsd => "openbsd",
    .dragonfly => "dragonfly",
    .illumos => "illumos",
    else => "posix",
};

const arch_name = if (builtin.os.tag == .emscripten)
    "wasm"
else switch (builtin.cpu.arch) {
    .x86_64 => "x64",
    .x86 => "x86",
    .aarch64 => "aarch64",
    .arm, .armeb, .thumb, .thumbeb => "arm",
    .riscv64 => "riscv64",
    .riscv32 => "riscv32",
    .sparc, .sparc64 => "sparc",
    .powerpc, .powerpcle => "ppc",
    .powerpc64, .powerpc64le => "ppc64",
    .s390x => "s390x",
    else => "unknown",
};

const compiler_name = if (builtin.abi == .msvc) "msvc" else "clang";

pub fn osName() [*:0]const u8 {
    return os_name;
}

pub fn osArch() [*:0]const u8 {
    return arch_name;
}

pub fn osCompiler() [*:0]const u8 {
    return compiler_name;
}

/// Return the same approximation families used by os.c, or -1 when that C
/// implementation would return the caller's fallback value. Linux preserves
/// the C path's zero result when querying affinity fails.
pub fn osCpuCount() i32 {
    switch (builtin.os.tag) {
        .illumos => {
            const count = std.c.sysconf(@intFromEnum(std.c._SC.NPROCESSORS_CONF));
            return if (count < 0) -1 else @intCast(count);
        },
        .windows, .linux, .freebsd, .netbsd, .openbsd, .dragonfly => {
            const count = std.Thread.getCpuCount() catch
                return if (builtin.os.tag == .linux) 0 else -1;
            return std.math.cast(i32, count) orelse std.math.maxInt(i32);
        },
        else => return -1,
    }
}

// -------------------------------------------------------------------------
// The environment -- what `os_environ.zig` was.
// -------------------------------------------------------------------------

extern fn getenv(name: [*:0]const u8) callconv(.c) ?[*:0]const u8;
extern fn setenv(name: [*:0]const u8, value: [*:0]const u8, overwrite: c_int) callconv(.c) c_int;
extern fn unsetenv(name: [*:0]const u8) callconv(.c) c_int;
extern fn _putenv_s(name: [*:0]const u8, value: [*:0]const u8) callconv(.c) c_int;

pub fn environCount(environ: ?[*]const ?[*:0]u8) i32 {
    var count: i32 = 0;
    while (environ.?[@intCast(count)] != null) count += 1;
    return count;
}

pub fn environSeparator(entry: [*:0]const u8) i32 {
    var index: i32 = 0;
    while (entry[@intCast(index)] != 0) : (index += 1) {
        if (entry[@intCast(index)] == '=') return index;
    }
    return -1;
}

pub fn environGet(name: [*:0]const u8) ?[*:0]const u8 {
    return getenv(name);
}

pub fn environSet(name: [*:0]const u8, val: ?[*:0]const u8) i32 {
    if (builtin.os.tag == .windows) {
        return _putenv_s(name, val orelse "");
    }
    return if (val) |bytes| setenv(name, bytes, 1) else unsetenv(name);
}
