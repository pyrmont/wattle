//! The `os/` module: what the host is, what time it is, and what is in the
//! environment.
//!
//! One name, because Janet publishes one: `os`. The cfunctions and the time,
//! platform and environment kernels are all here, and the pieces that keep
//! names of their own are beside this file in `os/`.
//!
//! The bodies are compiled unconditionally and the registration is what is
//! gated. `-Dreduced-os=true` leaves only `os/exit`, `os/which`, `os/arch` and
//! `os/compiler` registered, since `libOs` pushes `selfEntries()` and nothing
//! else, and the kernels behind the rest are still compiled, which is what
//! keeps them type-checked in a configuration that does not offer them.
//! `boot.janet` substitutes a macro for `os/isatty` where the binding is
//! absent, which is the one place the reduced build behaves differently from a
//! binding that simply is not there.
//!
//! The environment lock is taken across each of the four environment
//! cfunctions, and it is a no-op in every build this tree can produce;
//! `os/abi.zig` has the reasoning. The places it is taken are what a future
//! threaded build would need, and `os/getenv` in particular takes it across
//! the copy of the borrowed `c.getenv` result rather than only across the
//! call.

// ==========================================================================
// Standard library imports
// ==========================================================================

const std = @import("std");
const builtin = @import("builtin");

// ==========================================================================
// Project imports
// ==========================================================================

const args_core = @import("args.zig");
const buffers = @import("value/buffers.zig");
const c = @import("cabi");
const config = @import("config");
const corefn = @import("corefn.zig");
const io_core = @import("io.zig");
const oa = @import("os/abi.zig");
const order = @import("value/helpers/order.zig");
const os_calendar = @import("os/date.zig");
const os_files = @import("os/fs.zig");
const os_procs = @import("os/process.zig");
const pp_format = @import("pp/format.zig");
const raise = @import("../api/raise.zig");
const repr = @import("repr");
const stdio = @import("stdio.zig");
const tables = @import("value/tables.zig");
const tuples = @import("value/tuples.zig");
const utils = @import("utils.zig");
const value = @import("value.zig");
const vm_lifecycle = @import("vm/lifecycle.zig");
const wrap = @import("value/helpers/wrap.zig");

/// `os/abi.zig`'s translation, which is where the `LC_*` constants come from.
const h = oa.h;

// ==========================================================================
// Constants
// ==========================================================================

/// The architecture name `os/arch` reports, derived from the target unless the
/// build overrode it.
const arch_name = switch (builtin.cpu.arch) {
    .wasm32, .wasm64 => "wasm",
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

/// The `-Dos-name` and `-Darch-name` build overrides. Where one is set it wins
/// over the derived name.
const arch_name_override: ?[:0]const u8 = if (config.arch_name) |n| n ++ "" else null;
const os_name_override: ?[:0]const u8 = if (config.os_name) |n| n ++ "" else null;

/// The three clocks `os/clock` accepts, with the numbers the host arm below
/// switches on.
const clock_sources = [_]struct { name: [:0]const u8, value: i32 }{
    .{ .name = "realtime", .value = 0 },
    .{ .name = "monotonic", .value = 1 },
    .{ .name = "cputime", .value = 2 },
};

/// The compiler name `os/compiler` reports.
const compiler_name = if (builtin.abi == .msvc) "msvc" else "clang";

/// Whether this build has the event loop, which decides whether `os/open` is
/// registered.
const has_ev = os_files.has_ev;

/// The number of 100-nanosecond intervals in a second, which is the unit a
/// Windows file time counts in.
const hundred_ns_per_second: i64 = 10000000;

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

/// Whether this build registers `os/setlocale`.
const no_locales = !config.locales;

/// Whether this build registers the process family.
const no_processes = !config.processes;

/// The operating system name `os/which` reports, derived from the target
/// unless the build overrode it.
const os_name = switch (builtin.os.tag) {
    .windows => switch (builtin.abi) {
        .gnu => "mingw",
        else => "windows",
    },
    .macos, .ios, .tvos, .watchos, .visionos => "macos",
    .emscripten => "web",
    .wasi => "wasi",
    .linux => "linux",
    .hurd => "hurd",
    .freebsd => "freebsd",
    .netbsd => "netbsd",
    .openbsd => "openbsd",
    .dragonfly => "dragonfly",
    .illumos => "illumos",
    else => "posix",
};

/// Whether this is a Plan 9 build. There is no Zig target for it, so `os.c`'s
/// Plan 9 arms are recorded rather than written.
const plan9 = false; // No Zig target; `os.c`'s Plan 9 arms are recorded, not written.

/// Whether this build registers only the four cfunctions that need no host
/// service.
const reduced_os = config.reduced_os;

/// The three clock sources, matching `clock_sources` above.
const source_cputime: i32 = 2;
const source_monotonic: i32 = 1;
const source_realtime: i32 = 0;

/// Whether this target takes the Windows arm of the clocks, the environment
/// and the sleep.
const windows = builtin.os.tag == .windows;

/// Windows file times count 100-nanosecond intervals from January 1, 1601.
const windows_epoch_offset: i64 = 116444736000000000;

// ==========================================================================
// Types
// ==========================================================================

/// A clock reading, split the way every caller needs it.
///
/// The parts stay separate rather than becoming a `struct timespec` because
/// that structure's layout varies by platform, libc and word size; `Timespec`
/// below is the one place that spells it.
pub const TimeParts = struct { sec: i64, nsec: i64 };

/// The host's `struct timespec`.
///
/// `std.timespec` everywhere it is a real declaration, which is every POSIX
/// target and is the type `gettime` above already hands to `clock_gettime`, so
/// naming it here adds no exposure this file did not already have. Windows is
/// not one of those targets: `std.time_t` is `void` there, because Zig's
/// `std.c` describes a libc Windows does not have, and the field types
/// therefore do not exist. mingw-w64's own declaration is
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

// ==========================================================================
// Public functions
// ==========================================================================

/// How many entries the environment vector has.
pub fn environCount(environ: ?[*]const ?[*:0]u8) i32 {
    var count: i32 = 0;
    while (environ.?[@intCast(count)] != null) count += 1;
    return count;
}

/// The value of one environment entry, borrowed from the vector.
pub fn environGet(name: [*:0]const u8) ?[*:0]const u8 {
    return c.getenv(name);
}

/// Where the `=` sits in an environment entry, which is what splits a name
/// from its value.
pub fn environSeparator(entry: [*:0]const u8) i32 {
    var index: i32 = 0;
    while (entry[@intCast(index)] != 0) : (index += 1) {
        if (entry[@intCast(index)] == '=') return index;
    }
    return -1;
}

/// Replaces the environment vector.
pub fn environSet(name: [*:0]const u8, val: ?[*:0]const u8) i32 {
    if (builtin.os.tag == .windows) {
        return c._putenv_s(name, val orelse "");
    }
    return if (val) |bytes| c.setenv(name, bytes, 1) else c.unsetenv(name);
}

/// Reads a clock source, reporting seconds and nanoseconds separately.
///
/// Nothing comes back where the clock could not be read, which is the -1 the C
/// shim returned. An unrecognised source falls back to the real-time clock, as
/// the C implementation's initialised-then-overwritten clock id does.
pub fn gettime(source: i32) ?TimeParts {
    if (windows) {
        switch (source) {
            source_monotonic => {
                var count: i64 = undefined;
                var frequency: i64 = undefined;
                _ = c.QueryPerformanceCounter(&count);
                _ = c.QueryPerformanceFrequency(&frequency);
                const remainder = @rem(count, frequency);
                return .{
                    .sec = @divTrunc(count, frequency),
                    .nsec = @divTrunc(remainder * 1000000000, frequency),
                };
            },
            source_cputime => {
                var creation: c.FILETIME = undefined;
                var exit_time: c.FILETIME = undefined;
                var kernel: c.FILETIME = undefined;
                var user: c.FILETIME = undefined;
                _ = c.GetProcessTimes(c.GetCurrentProcess(), &creation, &exit_time, &kernel, &user);
                const ticks = fileTimeToInt(user);
                return .{
                    .sec = @divTrunc(ticks, hundred_ns_per_second),
                    .nsec = @rem(ticks, hundred_ns_per_second) * 100,
                };
            },
            else => {
                var ft: c.FILETIME = undefined;
                c.GetSystemTimeAsFileTime(&ft);
                const ticks = fileTimeToInt(ft) - windows_epoch_offset;
                return .{
                    .sec = @divTrunc(ticks, hundred_ns_per_second),
                    .nsec = @rem(ticks, hundred_ns_per_second) * 100,
                };
            },
        }
    }

    const clock_id: std.c.clockid_t = switch (source) {
        source_monotonic => .MONOTONIC,
        source_cputime => .PROCESS_CPUTIME_ID,
        else => .REALTIME,
    };
    var spec: std.c.timespec = undefined;
    if (std.c.clock_gettime(clock_id, &spec) != 0) return null;
    return .{ .sec = @intCast(spec.sec), .nsec = @intCast(spec.nsec) };
}

/// The `struct timespec` abi over `gettime` above.
///
/// The Zig kernel reports seconds and nanoseconds separately, and something
/// has to put them into a `timespec`.
///
/// A translated `struct timespec` cannot be named from Zig, since musl
/// declares its padding as a bitfield and `translate-c` demotes any structure
/// with one to an opaque type. `std.timespec` can, being Zig's own declaration
/// of the same layout, and it is what this file already uses for
/// `clock_gettime` and `nanosleep`.
///
/// `enum JanetTimeSource` crosses as `c_uint`, which is what clang gives an
/// enumeration whose enumerators are all non-negative. `test/os_time.zig`
/// calls this with the enum directly, including a value outside it, so the
/// width is checked rather than assumed.
///
/// Nothing in the runtime calls it: every Zig caller uses `gettime` and takes
/// the parts. It is kept because it is a published symbol.
pub fn gettimeAbi(spec: *Timespec, source: c_uint) c_int {
    const now = gettime(@bitCast(source)) orelse return -1;
    spec.sec = @intCast(now.sec);
    spec.nsec = @intCast(now.nsec);
    return 0;
}

/// Registers the `os/` family, which is four cfunctions in a reduced build and
/// the whole table otherwise.
pub fn libOs(env: *tables.Table) raise.Error!void {
    // Upstream's `os/` registration opens with a Windows critical-section
    // initialisation guarded by `JANET_THREADS`, which no build in this tree
    // defines. It is recorded here rather than written: a branch no
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
        // the high-resolution clock, which is upstream's `os/` order.
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

/// The architecture name, as `os/arch` reports it.
pub fn osArch() [*:0]const u8 {
    return arch_name;
}

/// The compiler name, as `os/compiler` reports it.
pub fn osCompiler() [*:0]const u8 {
    return compiler_name;
}

/// The same approximation families `os.c` uses, or -1 where that
/// implementation would return the caller's fallback value. Linux keeps the C
/// path's zero result where querying affinity fails.
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

/// The operating system name, as `os/which` reports it.
pub fn osName() [*:0]const u8 {
    return os_name;
}

/// Suspends the caller for `seconds`, which the caller has already checked is
/// not negative.
///
/// Janet zeroes the fractional part above `UINT32_MAX` seconds, because the
/// subtraction it uses to isolate that part goes through a `uint32_t`; that is
/// preserved. Converting the whole-second part of a very large delay is
/// undefined in C, so this saturates instead. Both cases are far longer than
/// any process runs.
pub fn sleepFor(seconds: f64) void {
    if (windows) {
        c.Sleep(saturatingCast(u32, seconds * 1000));
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
    // `nanosleep` writes what is left of the interval back into `spec`, so a
    // retry after a signal sleeps the remainder rather than starting again.
    _ = c.retryIntr(std.c.nanosleep, .{ &spec, &spec });
}

/// Whole seconds since the Unix epoch, as `os/time` reports them.
pub fn timeNow() f64 {
    return @floatFromInt(c.time(null));
}

// ==========================================================================
// Private functions
// ==========================================================================

/// `(os/arch)`.
fn cfunArch(argv: []repr.Value) raise.Error!repr.Value {
    try args_core.fixarity(argv, 0);
    if (arch_name_override) |name| return value.fromBytes(name, .keyword);
    return value.fromBytes(std.mem.span(osArch()), .keyword);
}

/// `(os/clock &opt source format)`.
fn cfunClock(argv: []repr.Value) raise.Error!repr.Value {
    try vm_lifecycle.sandboxAssert(vm_lifecycle.Sandbox.of(&.{"hrtime"}));
    try args_core.arity(argv, 0, 2);

    const sourcestr = try args_core.optKeyword(argv, 0, null);
    var source: i32 = clock_sources[0].value;
    if (sourcestr) |wanted| {
        source = for (clock_sources) |entry| {
            if (utils.cstrcmp(wanted, entry.name.ptr) == 0) break entry.value;
        } else return pp_format.panicf(
            "expected :realtime, :monotonic, or :cputime, got %v",
            .{argv[0]},
        );
    }

    const now = gettime(source) orelse return raise.panic("could not get time");
    const sec = now.sec;
    const nsec = now.nsec;

    const formatstr = try args_core.optKeyword(argv, 1, null);
    // An absent format is `:double`, and its arm is the fallthrough below
    // rather than the first test: the comparisons keep C's order.
    if (formatstr) |wanted| {
        if (utils.cstrcmp(wanted, "double") != 0) {
            if (utils.cstrcmp(wanted, "int") == 0) {
                return wrap.fromNumber(@floatFromInt(sec));
            } else if (utils.cstrcmp(wanted, "tuple") == 0) {
                var tup = [2]repr.Value{
                    wrap.fromNumber(@floatFromInt(sec)),
                    wrap.fromNumber(@floatFromInt(nsec)),
                };
                return wrap.fromTuple(tuples.newFrom(&tup));
            }
            return pp_format.panicf("expected :double, :int, or :tuple, got %v", .{argv[1]});
        }
    }
    const dtime = @as(f64, @floatFromInt(sec)) + (@as(f64, @floatFromInt(nsec)) / 1e9);
    return wrap.fromNumber(dtime);
}

/// `(os/compiler)`.
fn cfunCompiler(argv: []repr.Value) raise.Error!repr.Value {
    try args_core.fixarity(argv, 0);
    return value.fromBytes(std.mem.span(osCompiler()), .keyword);
}

/// `(os/cpu-count &opt dflt)`.
fn cfunCpuCount(argv: []repr.Value) raise.Error!repr.Value {
    try args_core.arity(argv, 0, 1);
    const count = osCpuCount();
    if (count < 0) return if (argv.len > 0) argv[0] else wrap.fromNil();
    return wrap.fromInteger(count);
}

/// `(os/cryptorand n &opt buf)`.
fn cfunCryptorand(argv: []repr.Value) raise.Error!repr.Value {
    try args_core.arity(argv, 1, 2);
    const n = try args_core.getInteger(argv, 0);
    if (n < 0) return raise.panic("expected positive integer");
    var buffer: *buffers.Buffer = undefined;
    const count: usize = @intCast(n);
    var offset: usize = 0;
    if (argv.len == 2) {
        buffer = try args_core.getBuffer(argv, 1);
        offset = buffer.count;
    } else {
        buffer = buffers.new(count);
    }
    try buffers.setcount(buffer, offset + count);
    if (utils.cryptorand(buffer.data.? + offset, count) != 0) {
        return raise.panic("unable to get sufficient random data");
    }
    return wrap.fromBuffer(buffer);
}

/// `(os/environ)`.
fn cfunEnviron(argv: []repr.Value) raise.Error!repr.Value {
    try vm_lifecycle.sandboxAssert(vm_lifecycle.Sandbox.of(&.{"env"}));
    try args_core.fixarity(argv, 0);
    oa.lockEnviron();
    const env = oa.getEnviron();
    const nenv: usize = @intCast(environCount(env));
    const t = tables.new(@intCast(nenv));
    for (0..nenv) |i| {
        const e: [*:0]const u8 = @ptrCast(env.?[i]);
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

/// `(os/exit &opt x force)`.
fn cfunExit(argv: []repr.Value) raise.Error!repr.Value {
    try args_core.arity(argv, 0, 2);
    try vm_lifecycle.sandboxAssert(vm_lifecycle.Sandbox.of(&.{"exit"}));
    var status: c_int = 0;
    if (argv.len == 0) {
        status = 0;
    } else if (args_core.checkint(argv[0])) {
        status = wrap.toInteger(argv[0]);
    } else {
        // The docstring promises the hash of a non-integer and the code
        // exits with 1 instead.
        status = 1;
    }
    const force = argv.len >= 2 and repr.truthy(argv[1]);
    vm_lifecycle.deinitAbi();
    if (force) c._Exit(status);
    c.exit(status);
}

/// `(os/getenv variable &opt dflt)`.
fn cfunGetenv(argv: []repr.Value) raise.Error!repr.Value {
    try vm_lifecycle.sandboxAssert(vm_lifecycle.Sandbox.of(&.{"env"}));
    try args_core.arity(argv, 1, 2);
    const cstr = try args_core.getCString(argv, 0);
    oa.lockEnviron();
    const res = environGet(cstr);
    const ret = if (res) |val|
        value.fromBytes(std.mem.span(val), .string)
    else if (argv.len == 2)
        argv[1]
    else
        wrap.fromNil();
    oa.unlockEnviron();
    return ret;
}

/// `(os/isatty &opt file)`.
fn cfunIsatty(argv: []repr.Value) raise.Error!repr.Value {
    try args_core.arity(argv, 0, 1);
    const f: ?*io_core.FILE = if (argv.len == 1)
        try io_core.getfile(argv, 0, null)
    else
        stdio.out();
    if (windows) {
        const fd = c._fileno(f);
        if (fd == -1) return raise.panic("not a valid stream");
        return wrap.fromBoolean(c._isatty(fd) != 0);
    }
    const fd = c.fileno(f);
    if (fd == -1) return raise.panic(@ptrCast(utils.strerrorSafe(c.errno())));
    return wrap.fromBoolean(c.isatty(fd) != 0);
}

/// `(os/setenv variable value)`.
///
/// It declares an arity of one to two and reads two arguments, so
/// `(os/setenv "K")` unsets. The result of the host call is discarded, so a
/// refusal is not reported.
fn cfunSetenv(argv: []repr.Value) raise.Error!repr.Value {
    try vm_lifecycle.sandboxAssert(vm_lifecycle.Sandbox.of(&.{"env"}));
    try args_core.arity(argv, 1, 2);
    const ks = try args_core.getCString(argv, 0);
    const vs = try args_core.optCString(argv, 1, null);
    oa.lockEnviron();
    _ = environSet(ks, vs);
    oa.unlockEnviron();
    return wrap.fromNil();
}

/// `(os/setlocale &opt locale category)`.
fn cfunSetlocale(argv: []repr.Value) raise.Error!repr.Value {
    try args_core.arity(argv, 0, 2);
    const locale_name = try args_core.optCString(argv, 0, null);
    var category: c_int = h.LC_ALL;
    if (argv.len > 1 and !repr.checkType(argv[1], repr.Tag.nil)) {
        category = for (locale_categories) |entry| {
            if (args_core.keyeq(argv[1], entry.name.ptr)) break entry.value;
        } else return pp_format.panicf(
            "expected one of :all, :collate, :ctype, :monetary, :numeric, or :time, got %v",
            .{argv[1]},
        );
    }
    const old = c.setlocale(category, @ptrCast(locale_name)) orelse return wrap.fromNil();
    return value.fromBytes(std.mem.span(old), .string);
}

/// `(os/sleep n)`.
fn cfunSleep(argv: []repr.Value) raise.Error!repr.Value {
    try args_core.fixarity(argv, 1);
    const delay = try args_core.getNumber(argv, 0);
    // A negative delay, a NaN and a value outside `time_t`'s range are one
    // refusal: none of them names a duration. `math/int-max` is how a caller
    // asks for the longest duration there is.
    if (delay < 0 or !os_files.secondsFitTimeT(delay)) {
        return raise.panic("invalid argument to sleep");
    }
    sleepFor(delay);
    return wrap.fromNil();
}

/// `(os/time)`.
fn cfunTime(argv: []repr.Value) raise.Error!repr.Value {
    try args_core.fixarity(argv, 0);
    return wrap.fromNumber(timeNow());
}

/// `(os/which)`.
fn cfunWhich(argv: []repr.Value) raise.Error!repr.Value {
    try args_core.arity(argv, 0, 1);
    if (argv.len == 1 and repr.truthy(argv[0])) {
        _ = try args_core.getKeyword(argv, 0); // Constrain to keywords.
        return wrap.fromBoolean(order.equals(argv[0], value.fromBytes(std.mem.span(whichName()), .keyword)));
    }
    return value.fromBytes(std.mem.span(whichName()), .keyword);
}

/// The two clock registrations, which are `os/clock` and `os/time`.
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

/// A Windows `FILETIME` as the 64-bit count it is two halves of.
fn fileTimeToInt(ft: c.FILETIME) i64 {
    return @as(i64, ft.low) | (@as(i64, ft.high) << 32);
}

/// The high-resolution clock registrations, which upstream's `os/` order puts
/// last.
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

/// The rows between `os/cpu-count` and the filesystem family, in registration
/// order. `os/cwd`, `os/perm-string` and `os/perm-int` sit in the middle of
/// this run and are `os/fs.zig`'s, which is what makes the table an assembly
/// of pieces rather than a concatenation file by file.
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

/// Converts toward zero, clamping instead of trapping. This reproduces the
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

/// The four registrations a reduced build keeps: the ones that need no host
/// service beyond what the process already has.
fn selfEntries() []const corefn.Entry {
    const list = comptime blk: {
        var acc: []const corefn.Entry = &.{};
        acc = acc ++ [_]corefn.Entry{
            corefn.reg("os/exit", &cfunExit, @src(), "(os/exit &opt x force)", "Exit from janet with an exit code equal to x. If x is not an integer, " ++
                "exits with status 1. If `force` is truthy will exit immediately and " ++
                "skip cleanup code."),
            corefn.reg("os/which", &cfunWhich, @src(), "(os/which &opt test)", "Check the current operating system. If `test` is nil or unset, Returns one of:\n\n" ++
                "* :windows\n\n* :mingw\n\n* :cygwin\n\n* :macos\n\n" ++
                "* :web - Web assembly (emscripten)\n\n* :wasi - WebAssembly System Interface\n\n" ++
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

/// The registrations after the clocks, which is the environment family and the
/// process family.
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

/// The name a build override supplies, or the derived one.
fn whichName() [*:0]const u8 {
    if (os_name_override) |name| return name.ptr;
    return osName();
}
