//! Behavioral contract for the `os/` cfunction surface.
//!
//! `test/suite-os.wattle` has fifty-eight assertions and every one of them is
//! about what an `os/` function returns. Four things about this subsystem are
//! invisible from there, and they are what this file is for.
//!
//! The registration *table* is the first. Its contents decide what exists, its
//! order is what a method walk reports, and its docstring and source-map
//! columns are what `(doc ...)` reads. A surface assembled from four files can
//! get every function right and the order wrong, and no Janet assertion would
//! notice. `os.libOs` concatenates seven slices, so the order is something
//! that can break.
//!
//! The second is the stat reader. Janet sees only the values built on top of
//! it, so what it owes has no spelling on that side: the field indices, the
//! zeroing of the slots no platform writes, and the -1 for a path that cannot
//! be stat'ed.
//!
//! The third is the `core/process` abstract type's shape: which of its
//! fourteen callbacks are null is a fact about the type rather than about any
//! process, and the value's own head is the only way to ask.
//!
//! The fourth is the signal table. `os_process.zig` has the *names* and
//! reports a position; the surface has the number each position stands for on
//! this platform. Only the pair together produce a signal, and `os/proc-kill`
//! shows a caller nothing but "it worked" or "undefined signal".
//!
//! ## How the subjects are reached
//!
//! The stat reader and the field registry are reached by import, so the reader
//! this file drives is the one `os/stat` uses.
//!
//! The source-map order check is unconditional: every source path in the image
//! is `src/`-relative, so the loop runs in every configuration.
//!
//! A reduced-OS build is skipped rather than compiled away. The subject is
//! still compiled in that configuration, four `os/` functions of the forty-odd
//! below, so the skip says which it is rather than pretending the file does
//! not exist.

// ==========================================================================
// Standard library imports
// ==========================================================================

const std = @import("std");
const builtin = @import("builtin");

// ==========================================================================
// Project imports
// ==========================================================================

const args_core = @import("subsystems").args;
const config = @import("config");
const ev = @import("subsystems").ev;
const expect = @import("expect.zig").expect;
const harness = @import("harness.zig");
const host_stat = subsystems.host_stat;
const os_files = subsystems.fs;
const os_stat = subsystems.stat;
const repr = @import("repr");
const strings = @import("subsystems").value.strings;
const maps = @import("subsystems").value.maps;
const subsystems = @import("subsystems");
const tables = @import("subsystems").value.tables;
const utils = @import("subsystems").utils;
const value = @import("subsystems").value;
const vm_lifecycle = @import("subsystems").lifecycle;
const wrap = @import("subsystems").value.wrap;

// ==========================================================================
// Constants
// ==========================================================================

/// Every `os/` binding this configuration must define, listed in the order
/// `os.libOs` registers them so that the list can be read beside the table.
/// `theRegistration` below says what is and is not asserted about that order,
/// which is less than the listing suggests.
const expected_bindings: []const [*:0]const u8 = blk: {
    var list: []const [*:0]const u8 = &.{
        "os/exit",
        "os/which",
        "os/arch",
        "os/compiler",
        "os/cpu-count",
        "os/cwd",
        "os/cryptorand",
        "os/perm-string",
        "os/perm-int",
        "os/mktime",
        "os/time",
        "os/date",
        "os/strftime",
        "os/sleep",
        "os/isatty",
    };
    if (!no_locales) list = list ++ [_][*:0]const u8{"os/setlocale"};
    list = list ++ [_][*:0]const u8{
        "os/environ",
        "os/getenv",
        "os/setenv",
        "os/dir",
        "os/stat",
        "os/lstat",
        "os/chmod",
        "os/touch",
        "os/realpath",
        "os/cd",
    };
    if (!no_umask) list = list ++ [_][*:0]const u8{"os/umask"};
    if (!no_symlinks) list = list ++ [_][*:0]const u8{"os/readlink"};
    list = list ++ [_][*:0]const u8{
        "os/mkdir",
        "os/rmdir",
        "os/rm",
        "os/link",
        "os/rename",
    };
    if (!no_symlinks) list = list ++ [_][*:0]const u8{"os/symlink"};
    if (!no_processes) {
        list = list ++ [_][*:0]const u8{
            "os/execute",
            "os/spawn",
            "os/shell",
            "os/posix-fork",
            "os/posix-exec",
            "os/posix-chroot",
            "os/proc-wait",
            "os/proc-kill",
            "os/proc-close",
            "os/getpid",
        };
        if (harness.has_ev) list = list ++ [_][*:0]const u8{"os/sigaction"};
    }
    list = list ++ [_][*:0]const u8{"os/clock"};
    if (harness.has_ev) list = list ++ [_][*:0]const u8{ "os/open", "os/pipe" };
    break :blk list;
};

/// Whether the process functions are compiled *and* reachable. Every one of
/// them is POSIX-only in this contract's assertions.
const has_processes = !no_processes and !windows;
const no_cryptorand = !config.cryptorand;
const no_docstrings = !config.docstrings;
const no_locales = !config.locales;
const no_processes = !config.processes;
const no_sourcemaps = !config.sourcemaps;
const no_symlinks = os_files.no_symlinks;

/// The two the surface itself reads, so that this file cannot disagree with
/// its subject about which entry points exist.
const no_umask = os_files.no_umask;
const reduced_os = config.reduced_os;
/// The directory the sources below write in, which each of them names as
/// `<scratch>` and `scratchPath` splices this into.
///
/// `/tmp` rather than the working directory, for the reason
/// `theOptionalArguments` gives. WASI is the exception: a WASI program reaches
/// only the directories its host maps in, and the run step maps in the working
/// directory alone. The hazard that sends the others to `/tmp` is not there --
/// a mode-0000 file needs an `os/chmod` that does something, and on WASI it
/// does not.
const scratch = if (builtin.os.tag == .wasi)
    "wattle-os-surface-contract"
else
    "/tmp/wattle-os-surface-contract";

const windows = builtin.os.tag == .windows;

// ==========================================================================
// Aliased types
// ==========================================================================

/// The field identifiers, restated here so that a renumbering on either side
/// fails against a third copy rather than agreeing with itself.
/// `test/os_stat.zig` pins the *names* in their order; this pins the *numbers*
/// the stat reader writes at.
const Field = struct {
    const dev = 0;
    const inode = 1;
    const mode = 2;
    const int_permissions = 3;
    const permissions = 4;
    const uid = 5;
    const gid = 6;
    const nlink = 7;
    const rdev = 8;
    const size = 9;
    const blocks = 10;
    const blocksize = 11;
    const accessed = 12;
    const modified = 13;
    const changed = 14;
    const count = 15;
};

// ==========================================================================
// Cases
// ==========================================================================

/// One source with every `<scratch>` in it replaced by `scratch`.
///
/// The sources are comptime strings, so the splice is comptime too and each
/// call site still reads as one literal.
fn scratchPath(comptime source: []const u8) []const u8 {
    return comptime blk: {
        // One scan of each source, which is longer than the default quota.
        @setEvalBranchQuota(20000);
        var spliced: []const u8 = "";
        var rest: []const u8 = source;
        while (std.mem.indexOf(u8, rest, "<scratch>")) |at| {
            spliced = spliced ++ rest[0..at] ++ scratch;
            rest = rest[at + "<scratch>".len ..];
        }
        break :blk spliced ++ rest;
    };
}

fn bindingField(env: *tables.Table, name: [*:0]const u8, field: [*:0]const u8) repr.Value {
    const binding = tables.get(env, value.fromBytes(std.mem.span(name), .symbol));
    if (harness.isType(binding, repr.Tag.table)) {
        return tables.get(wrap.toTable(binding), value.fromBytes(std.mem.span(field), .keyword));
    }
    if (harness.isType(binding, repr.Tag.map)) {
        return maps.lookup(wrap.toMap(binding), value.fromBytes(std.mem.span(field), .keyword));
    }
    return wrap.fromNil();
}

fn theStatRead() void {
    expect(os_stat.fieldCount() == Field.count);
    expect(std.mem.eql(u8, std.mem.span(os_stat.fieldName(Field.dev).?), "dev"));
    expect(std.mem.eql(u8, std.mem.span(os_stat.fieldName(Field.size).?), "size"));
    expect(std.mem.eql(u8, std.mem.span(os_stat.fieldName(Field.changed).?), "changed"));

    // A path that cannot be stat'ed reports -1 and is the only failure this
    // reports at all; `errno` is not consulted by the caller.
    var mode: u32 = 0xABCD;
    var numbers: [Field.count]f64 = undefined;
    for (&numbers) |*n| n.* = -12345.0;
    expect(host_stat.statRead("no/such/path/xyz", false, &mode, &numbers) == -1);
    // Nothing is written on failure, including the mode.
    expect(mode == 0xABCD);
    expect(numbers[Field.size] == -12345.0);

    // A real path fills every slot. The three the caller never reads through
    // `numbers`, which is mode and the two permission renderings built from it,
    // are zero rather than indeterminate: a descriptor's unwritten fields are
    // part of its contract and nothing about the type says so.
    //
    // `build.zig` is the file asked for, because it is the one file whose
    // absence stops this contract from being built at all.
    expect(host_stat.statRead("build.zig", false, &mode, &numbers) == 0);
    expect(mode != 0);
    expect(numbers[Field.mode] == 0.0);
    expect(numbers[Field.int_permissions] == 0.0);
    expect(numbers[Field.permissions] == 0.0);
    expect(numbers[Field.size] > 0.0);
    expect(numbers[Field.nlink] >= 1.0);
    expect(numbers[Field.inode] > 0.0);
    expect(numbers[Field.modified] > 0.0);
    if (windows) {
        // The two slots no Windows stat has. They are zero because the array
        // is zeroed, not because anything wrote them.
        expect(numbers[Field.blocks] == 0.0);
        expect(numbers[Field.blocksize] == 0.0);
    } else if (builtin.os.tag == .wasi) {
        // WASI has both slots and fills neither: the file description
        // `wasi_snapshot_preview1` reports carries no block count and no block
        // size, so the reader copies the zeroes wasi-libc left there.
        expect(numbers[Field.blocks] == 0.0);
        expect(numbers[Field.blocksize] == 0.0);
    } else {
        expect(numbers[Field.blocksize] > 0.0);
    }

    // A directory and a file differ in the mode word and in nothing this
    // function decides: the classification is the caller's.
    var directory_mode: u32 = 0;
    expect(host_stat.statRead("src/runtime", false, &directory_mode, &numbers) == 0);
    expect(directory_mode != mode);
}

/// Registration *order* is not observable, so what is asserted here is the
/// *set*.
///
/// `os.libOs` puts its rows into the core environment, which is a hash table,
/// so nothing downstream can see which row came first. The source map is not a
/// way to read the order back either: `corefn.reg` records the line of the
/// registration row rather than of the definition, because `@src()` is valid
/// only inside a function and the row is where it is called.
///
/// The set catches a function dropped, added or duplicated, a duplicate making
/// the list longer than the environment.
///
/// The order check that follows is narrower still: it compares source-map
/// lines only where two consecutive names come from the same `src/` file,
/// so it catches two rows exchanged within one file and nothing across files.
fn theRegistration() void {
    const env: *tables.Table = harness.coreEnv();
    var count: i32 = 0;

    var previous_file: ?strings.String = null;
    var previous_line: i32 = -1;

    for (expected_bindings) |name| {
        const binding = tables.get(env, value.fromBytes(std.mem.span(name), .symbol));
        expect(!harness.isType(binding, repr.Tag.nil));
        expect(harness.isType(binding, repr.Tag.table) or harness.isType(binding, repr.Tag.map));
        count += 1;

        // `corefn.reg` drops the source map when the *bootstrap* was built
        // without one, and the runtime arm always keeps it. So the column
        // exists in every configuration except `-Dsourcemaps=false`, and
        // asking for it there is asking for something the build was told not
        // to record. The matrix has that entry.
        if (!no_sourcemaps) {
            const smap = bindingField(env, name, "source-map");
            expect(harness.isIndexed(smap));
            const tuple = harness.elems(smap);
            expect(tuple.len >= 2);
            expect(harness.isType(tuple[0], repr.Tag.string));
            expect(args_core.checkint(tuple[1]));

            const file = wrap.toString(tuple[0]);
            const line = wrap.toInteger(tuple[1]);
            const length: usize = strings.head(file).length;
            const from_zig = length > 4 and std.mem.eql(u8, file[0..4], "src/");
            if (from_zig and previous_file != null and
                strings.equal(previous_file.?, file))
            {
                expect(line > previous_line);
            }
            previous_file = file;
            previous_line = line;
        }
    }

    // And nothing outside the list: every `os/` symbol in the environment
    // has to be one this file named. A function added to the surface and left
    // out of `expected_bindings` fails here rather than silently, and a name
    // listed twice makes `count` exceed `found`.
    var found: i32 = 0;
    var i: i32 = 0;
    while (i < env.capacity) : (i += 1) {
        const key = env.slots()[@intCast(i)].key;
        if (!harness.isType(key, repr.Tag.symbol)) continue;
        const symbol = wrap.toSymbol(key);
        if (strings.head(symbol).length < 3) continue;
        if (!std.mem.eql(u8, symbol[0..3], "os/")) continue;
        found += 1;
        var matched = false;
        for (expected_bindings) |name| {
            if (utils.cstrcmp(symbol, name) == 0) matched = true;
        }
        expect(matched);
    }
    expect(found == count);

    // The docstring is `corefn.reg`'s other column, and a row that lost it
    // still registers a working function. The generator drops it under
    // `-Ddocstrings=false`, so the assertion follows the flag.
    if (!no_docstrings) {
        harness.inFiber(env,
            \\(assert (string? ((dyn 'os/stat) :doc)))
            \\(assert (string/has-prefix? "(os/stat path" ((dyn 'os/stat) :doc)))
            \\(assert (string? ((dyn 'os/date) :doc)))
        );
        if (!no_processes) {
            harness.inFiber(env,
                \\(assert (string? ((dyn 'os/spawn) :doc)))
            );
        }
    }
}

/// The calendar's three functions, which `suite-os.wattle` asserts nothing
/// about. Fixed timestamps rather than the current time, because the current
/// time agrees
/// with itself whatever it computes.
fn theCalendar() void {
    const env: *tables.Table = harness.coreEnv();
    harness.inFiber(env,
        \\(def d (os/date 0))
        \\(assert (= 1970 (d :year)))
        \\(assert (= 0 (d :month)))
        \\(assert (= 0 (d :month-day)))
        \\(assert (= 4 (d :week-day)))
        \\(assert (= 0 (d :year-day)))
        \\(assert (= false (d :dst)))
        \\(def d2 (os/date 1600000000))
        \\(assert (= 2020 (d2 :year)))
        \\(assert (= 8 (d2 :month)))
        \\(assert (= 12 (d2 :month-day)))
        \\(assert (= 1600000000 (os/mktime d2)))
        \\(assert (= 0 (os/mktime {:year 1970 :month 0 :month-day 0})))
        \\(assert (= 86400 (os/mktime {:year 1970 :month 0 :month-day 1})))
        \\(assert (= 0 (os/mktime !{:year 1970 :month 0 :month-day 0})))
        \\(assert (not (first (protect (os/mktime 5)))))
        \\(assert (not (first (protect (os/mktime {:year "x"})))))
        \\(assert (= "1970-01-01T00:00:00" (os/strftime "%Y-%m-%dT%H:%M:%S" 0)))
        \\(assert (= "100%" (os/strftime "100%%" 0)))
        \\(assert (= "" (os/strftime "" 0)))
        \\(assert (= "invalid conversion specifier '%Q'"
        \\           (in (protect (os/strftime "%Q" 0)) 1)))
        \\(assert (= "invalid conversion specifier"
        \\           (in (protect (os/strftime "abc%" 0)) 1)))
    );
}

/// The permission conversions have a fault message per slot, and the slot
/// number is part of it. The argument layer builds most of Janet's argument
/// messages; these two are the surface's own.
fn thePermissions() void {
    const env: *tables.Table = harness.coreEnv();
    harness.inFiber(env,
        \\(assert (= "rwxr-xr-x" (os/perm-string 8r755)))
        \\(assert (= "---------" (os/perm-string 0)))
        \\(assert (= 8r755 (os/perm-int "rwxr-xr-x")))
        \\(for i 0 8r1000 (assert (= i (os/perm-int (os/perm-string i)))))
        \\(assert (= "bad slot #0, expected integer in range [0, 8r777], got 512"
        \\           (in (protect (os/perm-string 8r1000)) 1)))
        \\(assert (= "bad slot #0: expected byte sequence of length 9, got \"rwx\""
        \\           (in (protect (os/perm-int "rwx")) 1)))
        \\(assert (not (first (protect (os/perm-string -1)))))
    );
}

/// `os/clock`'s three sources and three formats are nine combinations, of
/// which `suite-os.wattle` exercises none: a clock cannot be pinned to a value,
/// so the assertions are about the relationships between the formats instead.
fn theClock() void {
    const env: *tables.Table = harness.coreEnv();
    harness.inFiber(env,
        \\(each source [:realtime :monotonic :cputime]
        \\  (def d (os/clock source))
        \\  (def i (os/clock source :int))
        \\  (def t (os/clock source :vector))
        \\  (assert (number? d))
        \\  (assert (= i (math/floor i)))
        \\  (assert (= 2 (length t)))
        \\  (assert (and (<= 0 (in t 1)) (< (in t 1) 1000000000))))
        \\(assert (< (math/abs (- (os/clock) (os/clock :realtime))) 1))
        \\(assert (< (math/abs (- (os/time) (os/clock :realtime :int))) 2))
        \\(def before (os/clock :monotonic))
        \\(os/sleep 0.01)
        \\(assert (> (os/clock :monotonic) before))
        \\(assert (= "expected :realtime, :monotonic, or :cputime, got :bogus"
        \\           (in (protect (os/clock :bogus)) 1)))
        \\(assert (= "expected :double, :int, or :vector, got :bogus"
        \\           (in (protect (os/clock :realtime :bogus)) 1)))
    );
}

/// The environment lock is a no-op in every build this tree can produce, so
/// what is left to assert is the shape of what crosses it: `os/environ` must
/// preserve a value containing `=`, and an empty value is a value rather than
/// an absence.
fn theEnvironment() void {
    const env: *tables.Table = harness.coreEnv();
    harness.inFiber(env,
        \\(os/setenv "WATTLE_OS_SURFACE_A" "x=y=z")
        \\(assert (= "x=y=z" (os/getenv "WATTLE_OS_SURFACE_A")))
        \\(assert (= "x=y=z" (get (os/environ) "WATTLE_OS_SURFACE_A")))
        \\(os/setenv "WATTLE_OS_SURFACE_A" "")
        \\(assert (= "" (os/getenv "WATTLE_OS_SURFACE_A")))
        \\(assert (= "" (get (os/environ) "WATTLE_OS_SURFACE_A")))
        \\(os/setenv "WATTLE_OS_SURFACE_A")
        \\(assert (nil? (os/getenv "WATTLE_OS_SURFACE_A")))
        \\(assert (nil? (get (os/environ) "WATTLE_OS_SURFACE_A")))
        \\(assert (= :d (os/getenv "WATTLE_OS_SURFACE_A" :d)))
        \\(os/setenv "WATTLE_OS_SURFACE_A" "")
        \\(assert (= "" (os/getenv "WATTLE_OS_SURFACE_A" :d)))
        \\(os/setenv "WATTLE_OS_SURFACE_A")
    );
}

/// Platform introspection. The values are the host's, so the assertions are
/// about the shape of the result and about `os/which`'s two modes, which no
/// suite exercises.
fn thePlatform() void {
    const env: *tables.Table = harness.coreEnv();
    harness.inFiber(env,
        \\(assert (keyword? (os/which)))
        \\(assert (keyword? (os/arch)))
        \\(assert (keyword? (os/compiler)))
        \\(assert (= true (os/which (os/which))))
        \\(assert (= false (os/which :definitely-not-an-os)))
        \\(assert (keyword? (os/which nil)))
        \\(assert (keyword? (os/which false)))
        \\(assert (not (first (protect (os/which "linux")))))
        \\(assert (or (nil? (os/cpu-count)) (pos? (os/cpu-count))))
        \\; The argument is a fallback, so the answer is the count where there is
        \\; one and the fallback where there is not -- and `(os/cpu-count)` with
        \\; no argument is exactly the test for which. `(= 7 (os/cpu-count 7))`
        \\; asserts the fallback as though it were the answer: true on macOS,
        \\; where the count has no arm at all and comes back -1, and false in a
        \\; Linux container, where the count is real. The form below holds on
        \\; both hosts and is the stronger claim on each.
        \\(assert (= (os/cpu-count 7) (or (os/cpu-count) 7)))
    );
}

/// The optional-argument branches. Each of these is an `argc >` or an
/// `argc ==` that decides whether a slot is read at all, and inverting one
/// reads a slot that is not there or ignores one that is.
///
/// The files these open go under /tmp rather than the working directory,
/// because a failure part way through can leave a mode-0000 file behind and a
/// later run would then fail for a reason that has nothing to do with the
/// code.
fn theOptionalArguments() void {
    const env: *tables.Table = harness.coreEnv();
    harness.inFiber(env,
        \\(assert (number? ((os/date) :year)))
        \\(assert (= (os/date) (os/date nil)))
        \\(assert (= (os/date 0) (os/date 0 nil)))
        \\; `(os/date t)` renders UTC and `(os/date t true)` renders local, so the
        \\; two differ only where the host's zone is not UTC. Asserting
        \\; `(not= ...)` unconditionally is a claim about the developer's machine
        \\; wearing the shape of a claim about the argument: it fails in a
        \\; container, where the zone *is* UTC and the two coincide. Both forms
        \\; below are portable and each is the stronger claim.
        \\;
        \\; The no-flag branch, pinned absolutely: epoch zero is
        \\; 1970-01-01T00:00:00 UTC on every host there is.
        \\(def epoch (os/date 0))
        \\(assert (= [1970 0 0 0 0 0]
        \\           [(epoch :year) (epoch :month) (epoch :month-day)
        \\            (epoch :hours) (epoch :minutes) (epoch :seconds)]))
        \\; The flag branch, cross-checked against the other renderer rather than
        \\; against itself: `os/strftime` reads the zone from the same place and
        \\; takes the same optional argument, so agreeing is a real claim on a
        \\; UTC host and on any other.
        \\(assert (= (scan-number (os/strftime "%H" 0 true)) ((os/date 0 true) :hours)))
        \\(assert (= (scan-number (os/strftime "%H" 0)) (epoch :hours)))
        \\(assert (string? (os/strftime "%Y")))
        \\(assert (= (os/strftime "%Y" 0) (os/strftime "%Y" 0 nil)))
        \\(def base {:year 1970 :month 0 :month-day 0})
        \\; The `:dst` slot is observable only in a zone that *has* a daylight
        \\; rule. `(not= ...)` against whatever zone the host happened to be in
        \\; is a claim about the developer's machine: it passes in JST and fails
        \\; in a container, where the zone is UTC and forcing DST changes
        \\; nothing.
        \\;
        \\; A POSIX TZ string supplies the rule without tzdata, so it is the same
        \\; zone on every host -- Alpine ships no zoneinfo and musl parses the
        \\; string natively, as does Darwin. That makes the difference exactly
        \\; one hour rather than merely non-zero, which is the stronger claim and
        \\; the one the slot is actually for.
        \\;
        \\; WASI is where that argument runs out: it has no time zones and no
        \\; `tzset`, local time is UTC, and `TZ` names nothing. The slot is not
        \\; observable there at all.
        \\(unless (= :wasi (os/which))
        \\  (def saved-tz (os/getenv "TZ"))
        \\  (os/setenv "TZ" "EST5EDT,M3.2.0,M11.1.0")
        \\  (assert (= 3600 (- (os/mktime (merge base {:dst false}) true)
        \\                     (os/mktime (merge base {:dst true}) true))))
        \\  (assert (= 3600 (- (os/mktime (hash-map |(kvs base) :dst false) true)
        \\                     (os/mktime (hash-map |(kvs base) :dst true) true))))
        \\  (assert (= (os/mktime base true)
        \\             (os/mktime (merge base {:dst false}) true)))
        \\  (assert (= (os/mktime base true) (os/mktime (merge-into !{} base) true)))
        \\  (assert (= (os/mktime (merge base {:dst true}) true)
        \\             (os/mktime (hash-map |(kvs base) :dst true) true)))
        \\  (if saved-tz (os/setenv "TZ" saved-tz) (os/setenv "TZ")))
        \\(assert (= (os/mktime base) (os/mktime base nil)))
        \\(assert (= "expected positive integer" (in (protect (os/cryptorand -1)) 1)))
    );

    if (!no_cryptorand) {
        harness.inFiber(env,
            \\(assert (= 4 (length (os/cryptorand 4))))
            \\(def b !"XY")
            \\(assert (= b (os/cryptorand 4 b)))
            \\(assert (= 6 (length b)))
            \\(assert (= "XY" (string (buffer/slice b 0 2))))
            \\(assert (= 0 (length (os/cryptorand 0))))
        );
    } else {
        harness.inFiber(env,
            \\(assert (= "unable to get sufficient random data"
            \\           (in (protect (os/cryptorand 4)) 1)))
        );
    }

    if (!no_locales) {
        harness.inFiber(env,
            \\(each cat [:all :collate :ctype :monetary :numeric :time]
            \\  (assert (string? (os/setlocale nil cat)) (string "category " cat)))
            \\(assert (string? (os/setlocale nil)))
            \\(assert (string? (os/setlocale nil nil)))
        );
    }

    // `os/isatty` defaults to stdout and otherwise asks about its argument,
    // which under the contract driver is not a terminal.
    harness.inFiber(env,
        \\(def f (file/temp))
        \\(assert (= false (os/isatty f)))
        \\(file/close f)
    );
}

fn theOpenFlags() void {
    if (!harness.has_ev) return;
    var env: *tables.Table = harness.coreEnv();
    harness.inFiber(env, scratchPath(
        \\(os/mkdir "<scratch>")
        \\(defn p [n] (string "<scratch>/" n))
        \\(each n (os/dir "<scratch>") (os/rm (p n)))
        \\(spit (p "ro") "abc") (os/chmod (p "ro") 8r444)
        \\(spit (p "wo") "abc") (os/chmod (p "wo") 8r222)
        \\(spit (p "rw") "abc") (os/chmod (p "rw") 8r644)
        \\(def s (os/open (p "ro") :r))
        \\(assert (= "abc" (string (:read s 3))))
        \\(assert (= "bad stream, expected writable stream"
        \\           (in (protect (:write s "z")) 1)))
        \\(:close s)
        \\(def s2 (os/open (p "wo") :w))
        \\(:write s2 "z")
        \\(assert (= "bad stream, expected readable stream"
        \\           (in (protect (:read s2 1)) 1)))
        \\(:close s2)
        \\(def s3 (os/open (p "rw") :rw))
        \\(:write s3 "Q")
        \\(:close s3)
        \\(assert (= "Qbc" (string (slurp (p "rw")))))
    ));
    vm_lifecycle.deinit();

    harness.init();
    env = harness.coreEnv();
    harness.inFiber(env, scratchPath(
        \\(defn p [n] (string "<scratch>/" n))
        \\(def s (os/open (p "rw") :rN))
        \\(assert (= "bad stream, expected readable stream"
        \\           (in (protect (:read s 1)) 1)))
        \\(:close s)
        \\(spit (p "ap") "1")
        \\(def a (os/open (p "ap") :wa)) (:write a "2") (:close a)
        \\(assert (= "12" (string (slurp (p "ap")))))
        \\(spit (p "tr") "xyz")
        \\(:close (os/open (p "tr") :wt))
        \\(assert (= 0 (length (slurp (p "tr")))))
        \\(:close (os/open (p "ce") :wce))
        \\(assert (= "File exists" (in (protect (os/open (p "ce") :wce)) 1)))
        \\(:close (os/open (p "md") :wc 8r640))
        \\(assert (= "rw-r-----" (os/stat (p "md") :permissions)))
        \\(def z (os/open (p "rw") :rZ)) (:close z)
    ));
}

/// `os/rm` and the filesystem sandbox.
///
/// Every filesystem entry point asserts the permission its operation needs,
/// and `os/rm` and `os/readlink` are the two that once did not: `os/rm`
/// asserted nothing at all while its nine neighbours asserted `fs_write`, so a
/// sandboxed program could delete any file the process could reach, and
/// `os/readlink` asserted nothing where `os/stat`, `os/dir` and `os/realpath`
/// assert `fs_read`.
///
/// `sandbox` is irreversible within a VM, so this runs in a VM of its own and
/// does its setup before forbidding anything. The file it leaves
/// behind is cleaned by `theLinks`, which runs after it and removes the whole
/// scratch directory.
fn theRemoveSandbox() void {
    var env: *tables.Table = harness.coreEnv();
    harness.inFiber(env, scratchPath(
        \\(protect (os/mkdir "<scratch>"))
        \\(def victim (string "<scratch>/victim"))
        \\(spit victim "x")
        \\(assert (os/stat victim))
        \\(sandbox :fs-write)
        \\(assert (= "operation forbidden by sandbox"
        \\           (in (protect (os/rm victim)) 1)))
        \\(assert (os/stat victim) "the file survives a forbidden os/rm")
        \\(assert (= "operation forbidden by sandbox" (in (protect (os/rm)) 1)))
        \\(assert (= "operation forbidden by sandbox" (in (protect (os/rm 5)) 1)))
        \\(assert (= "operation forbidden by sandbox"
        \\           (in (protect (os/rmdir "<scratch>")) 1)))
    ));
    vm_lifecycle.deinit();

    // A fresh VM, because the one above can never leave its sandbox. Without a
    // sandbox the delete still works, which is the half of the behaviour that
    // must not have changed.
    harness.init();
    env = harness.coreEnv();
    harness.inFiber(env, scratchPath(
        \\(def victim (string "<scratch>/victim"))
        \\(assert (os/stat victim))
        \\(os/rm victim)
        \\(assert (nil? (os/stat victim)))
        \\(spit victim "x")
        \\(sandbox :fs-read)
        \\(os/rm victim)
    ));
}

/// `os/link`'s third argument decides between a hard link and a symbolic one,
/// and `os/symlink` is the same call with it forced true. Nothing above looked
/// at the argument at all.
fn theLinks() void {
    if (windows) return;
    const env: *tables.Table = harness.coreEnv();
    harness.inFiber(env, scratchPath(
        \\(protect (os/mkdir "<scratch>"))
        \\(defn p [n] (string "<scratch>/" n))
        \\(defn rm [n] (protect (os/rm (p n))))
        \\(rm "h") (rm "s") (rm "h2")
        \\(spit (p "tgt") "abc")
        \\(os/link (p "tgt") (p "h") false)
        \\(assert (= :file (os/lstat (p "h") :mode)))
        \\(assert (= 2 (os/stat (p "tgt") :nlink)))
        \\(os/link (p "tgt") (p "h2"))
        \\(assert (= :file (os/lstat (p "h2") :mode)))
        \\(assert (= 3 (os/stat (p "tgt") :nlink)))
        \\; A symbolic link stores its target as given and resolves it from the
        \\; link's own directory, so the target has to be one the link can
        \\; follow. Every host here but WASI reaches the scratch directory by an
        \\; absolute path, which resolves from anywhere; a WASI host refuses an
        \\; absolute target outright, it being a path out of the directory it
        \\; mapped in, so there the target is the name beside the link.
        \\(def target (if (= :wasi (os/which)) "tgt" (p "tgt")))
        \\(os/link target (p "s") true)
        \\(assert (= :link (os/lstat (p "s") :mode)))
        \\(assert (= :file (os/stat (p "s") :mode)))
        \\(assert (= target (os/readlink (p "s"))))
        \\(rm "s")
        \\(os/symlink target (p "s"))
        \\(assert (= :link (os/lstat (p "s") :mode)))
        \\(each n (os/dir "<scratch>") (protect (os/rm (p n))))
        \\(os/rmdir "<scratch>")
    ));
}

/// `os/pipe` and its two flag letters.
fn thePipe() void {
    if (!harness.has_ev) return;
    const env: *tables.Table = harness.coreEnv();
    harness.inFiber(env,
        \\(def [r w] (os/pipe))
        \\(:write w "abc")
        \\(assert (= "abc" (string (:read r 3))))
        \\(:close w) (:close r)
        \\(def [r2 w2] (os/pipe nil))
        \\(:close w2) (:close r2)
        \\(def [r3 w3] (os/pipe :W))
        \\(assert (= "bad stream, expected writable stream"
        \\           (in (protect (:write w3 "x")) 1)))
        \\(:close w3) (:close r3)
        \\(def [r4 w4] (os/pipe :R))
        \\(assert (= "bad stream, expected readable stream"
        \\           (in (protect (:read r4 1)) 1)))
        \\(:close w4) (:close r4)
    );
}

// `os/exit`'s `force` argument is *not* tested here.
//
// `force` chooses `_Exit` over `exit`, and the only visible difference is
// whether the C library's buffered output is flushed on the way out. That can
// only be asked of a child process running a Janet snippet, and this contract
// has no interpreter to spawn: `(dyn :executable)` is the CLI's binding and
// `core_env.coreEnv` does not set it, so a contract inside the runtime cannot
// name a `wattle` binary.

/// Which callbacks the type supplies is a fact about the type. A process is
/// not marshallable, has no string rendering, and does not compare or hash,
/// so `(marshal p)` must fail and `(string p)` must fall back on the generic
/// abstract rendering. A port that filled one of those in by accident would
/// pass every suite.
fn theProcessType() void {
    const env: *tables.Table = harness.coreEnv();
    harness.inFiber(env,
        \\(def null (file/open "/dev/null" :w))
        \\; `/usr/bin/true` stood here and at one site below. Alpine is busybox
        \\; and puts it at `/bin/true`, so both spawns died with ENOENT the first
        \\; time this contract ran off macOS.
        \\; `/bin/sh` is already this file's dependency a dozen lines down and is
        \\; the one path every POSIX host agrees on.
        \\(def p (os/spawn ["/bin/sh" "-c" "exit 0"] :p {:out null :err null}))
        \\(def at (type p))
        \\(assert (= :core/process at))
        \\(assert (= 0 (os/proc-wait p)))
        \\(assert (not (first (protect (marshal p)))))
        \\(assert (string/has-prefix? "<core/process " (string p)))
        \\(assert (deep= ![:wait :kill :close :in :out :err] (keys p)))
        \\(file/close null)
    );
}

/// The signal table: a name the platform defines resolves, and one it does not
/// reports "undefined signal" with the keyword in the message.
///
/// Two details here are about the *sweep* rather than about signals, and both
/// were forced by a false-catch channel a mutation run found. A child is given
/// an explicit stdout and stderr instead of inheriting this process's, because
/// the sweep runs a contract with its output captured and blocks until every
/// writer to the pipe closes, including a grandchild that outlived an
/// aborting contract. And the kill is *asserted* rather than merely performed,
/// so a mutated `os/proc-kill` that returns without killing fails an assertion
/// here rather than leaking a child that then keeps the harness's pipe for its
/// whole timeout.
///
/// SIGKILL is what the death assertion uses, and that is not fastidiousness:
/// an ignored disposition is inherited across fork and exec, `nohup` ignores
/// SIGHUP, and the sweep launches `mutate.py` with `nohup`. SIGKILL is the one
/// signal that cannot be caught or ignored.
fn theSignalTable() void {
    const env: *tables.Table = harness.coreEnv();
    harness.inFiber(env,
        \\(def null (file/open "/dev/null" :w))
        \\(defn sleeper [] (os/spawn ["/bin/sleep" "30"] :p {:out null :err null}))
        \\(each sig [:int :term :hup :usr1 :usr2 :alrm :chld :cont]
        \\  (def p (sleeper))
        \\  (def res (protect (os/proc-kill p false sig)))
        \\  (assert (first res) (string "signal " sig " resolves to a number"))
        \\  (assert (>= (os/proc-kill p true :kill) 128)
        \\          (string "the child of " sig " is killed")))
        \\(def k (sleeper))
        \\(assert (= 137 (os/proc-kill k true :kill)))
        \\(def d (sleeper))
        \\(assert (= 137 (os/proc-kill d true)))
        \\(def p (sleeper))
        \\(assert (= "undefined signal :nosuchsignal"
        \\           (in (protect (os/proc-kill p false :nosuchsignal)) 1)))
        \\(assert (>= (os/proc-kill p true) 128))
        \\; `:vtalrm` is the spelling the table carries -- the signal's own
        \\; name with the `SIG` dropped -- and the transposition is not an
        \\; alias for it.
        \\(def q (sleeper))
        \\(assert (= "undefined signal :vtlarm"
        \\           (in (protect (os/proc-kill q false :vtlarm)) 1)))
        \\(assert (>= (os/proc-kill q true) 128))
        \\(file/close null)
    );
}

/// `os/spawn`'s redirections and flags. Everything here needs a subprocess
/// that actually produces output or an exit code, so none of it is
/// reachable from the type-shape test above.
fn theSpawnRedirection() void {
    if (!harness.has_ev) return;
    var env: *tables.Table = harness.coreEnv();
    harness.inFiber(env,
        \\(def p (os/spawn ["/bin/sh" "-c" "exit 7"] :p))
        \\(assert (int? (p :pid)))
        \\(assert (string/has-prefix? "key :return-code not found"
        \\           (in (protect (p :return-code)) 1)))
        \\(assert (= 7 (os/proc-wait p)))
        \\(assert (= 7 (p :return-code)))
        \\(def q (os/spawn ["/bin/sh" "-c" "echo o; echo e 1>&2"] :p
        \\                 {:out :pipe :err :pipe}))
        \\(def qo (string (:read (q :out) :all)))
        \\(def qe (string (:read (q :err) :all)))
        \\(os/proc-wait q)
        \\(assert (= "o\n" qo))
        \\(assert (= "e\n" qe))
        \\(def r (os/spawn ["/bin/sh" "-c" "echo o; echo e 1>&2"] :p
        \\                 {:out :pipe :err :out}))
        \\(def ro (string (:read (r :out) :all)))
        \\(os/proc-wait r)
        \\(assert (= 2 (length (string/split "\n" (string/trim ro)))))
        \\(def t (os/spawn ["/bin/cat"] :p {:in :pipe :out :pipe}))
        \\(:write (t :in) "zz") (:close (t :in))
        \\(def to (string (:read (t :out) :all)))
        \\(os/proc-wait t)
        \\(assert (= "zz" to))
    );
    vm_lifecycle.deinit();

    harness.init();
    env = harness.coreEnv();
    harness.inFiber(env,
        \\(def f (file/temp))
        \\(def p (os/spawn ["/bin/echo" "ff"] :p {:out f}))
        \\(os/proc-wait p)
        \\(file/seek f :set 0)
        \\(assert (= "ff\n" (string (file/read f :all))))
        \\(file/close f)
        \\(def q (os/spawn ["/bin/echo" "x"] :p {:out :pipe}))
        \\(assert (number? (os/proc-close q)))
        \\(def r (os/spawn ["/bin/sh" "-c" "exit 0"] :p))
        \\(assert (= 0 (os/proc-wait r)))
        \\(assert (= nil (os/proc-close r)))
        \\(def s (os/spawn ["/bin/sh" "-c" "exit 3"] :px))
        \\(assert (= "command failed with non-zero exit code 3"
        \\           (in (protect (os/proc-wait s)) 1)))
        \\(def u (os/spawn ["/bin/sh" "-c" "exit 3"] :p))
        \\(assert (= 3 (os/proc-wait u)))
    );
}

/// The environment block `os/execute` builds under `:e`. Its POSIX arm drops a
/// key containing `=` or NUL and keeps everything else, which is a rule
/// `os_process.zig` owns and this is the only thing that runs it end to end.
fn theExecuteEnvironment() void {
    const env: *tables.Table = harness.coreEnv();
    harness.inFiber(env,
        \\(assert (= 0 (os/execute ["/bin/sh" "-c" "test \"$JP\" = v"] :pe {"JP" "v"})))
        \\(os/setenv "JP_PARENT" "set")
        \\(assert (= 0 (os/execute ["/bin/sh" "-c" "test -z \"$JP_PARENT\""] :pe {"JP" "v"})))
        \\(assert (= 0 (os/execute ["/bin/sh" "-c" "test \"$JP_PARENT\" = set"] :p)))
        \\(os/setenv "JP_PARENT")
        \\(assert (= 0 (os/execute ["/bin/sh" "-c" "test -z \"$JP\""] :pe {"J=P" "v"})))
        \\(assert (= 0 (os/execute ["/bin/sh" "-c" "true"] :pe {:kw "v" "k" 5})))
        \\(assert (= 0 (os/execute ["/bin/sh" "-c" "true"] :pe {})))
        \\(assert (not (first (protect (os/execute ["sh" "-c" "true"])))))
        \\(assert (= 0 (os/execute ["sh" "-c" "true"] :p)))
    );
}

/// `os/sigaction` installs, replaces and removes a handler, and the third
/// argument selects the interrupting trampoline. None of that is observable
/// from a return value, so what is asserted is that each shape is accepted and
/// that the signal table is consulted first.
fn theSigaction() void {
    if (!harness.has_ev) return;
    const env: *tables.Table = harness.coreEnv();
    harness.inFiber(env,
        \\(os/sigaction :usr1 (fn [] nil))
        \\(os/sigaction :usr1 (fn [] nil))
        \\(os/sigaction :usr1)
        \\(os/sigaction :usr1 nil)
        \\(os/sigaction :usr2 (fn [] nil) true)
        \\(os/sigaction :usr2 (fn [] nil) false)
        \\(os/sigaction :usr2)
        \\(assert (= "undefined signal :nosuchsignal"
        \\           (in (protect (os/sigaction :nosuchsignal (fn [] nil))) 1)))
        \\; A handler is entered with no arguments, so one that cannot accept
        \\; zero can never run: no fiber can be built for it. The refusal is at
        \\; registration, where the caller can still act on it.
        \\(assert (string/has-prefix?
        \\           "signal handler must accept zero arguments"
        \\           (in (protect (os/sigaction :usr1 (fn [x] nil))) 1)))
        \\; A handler with an optional parameter still accepts zero.
        \\(os/sigaction :usr1 (fn [&opt x] nil))
        \\(os/sigaction :usr1 nil)
    );
}

/// libc's `raise`, which runs the handler for a signal on the calling thread
/// before it returns.
extern fn raise(sig: c_int) callconv(.c) c_int;

/// `std.c.SIG` is an enum on some targets and a plain integer on others.
fn signalNumber(number: anytype) c_int {
    return switch (@typeInfo(@TypeOf(number))) {
        .@"enum" => @intCast(@intFromEnum(number)),
        else => @intCast(number),
    };
}

/// Which trampoline `os/sigaction` installs, read through the interrupt count.
/// The plain one only posts an event; the interrupting one, which the third
/// argument asks for, also counts an interrupt; and the callback that runs on
/// the loop takes the interrupt back for the interrupting one alone. So the
/// count stays put across a plain signal and rises by one until the loop
/// handles an interrupting one.
///
/// Each callback is run by one turn of the loop with nothing scheduled, which
/// polls, finds the posted event and returns, and the count is read before any
/// Janet code runs again. The loop runs no fiber while the count is not zero,
/// so a count the callback left wrong is seen here rather than as a loop that
/// never finishes.
fn theTrampolines() void {
    if (!harness.has_ev) return;
    const env: *tables.Table = harness.coreEnv();
    const vm = harness.vm();
    harness.inFiber(env, "(defglobal 'trampoline-hits ![nil nil])");
    harness.inFiber(env,
        \\(os/sigaction :usr1 (fn [] (set (trampoline-hits 0) :plain)))
        \\(os/sigaction :usr2 (fn [] (set (trampoline-hits 1) :interrupting)) true)
    );
    const before = vm.auto_suspend;

    _ = raise(signalNumber(std.c.SIG.USR1));
    expect(vm.auto_suspend == before);
    _ = ev.loop1() catch @panic("os_surface: the loop raised on a signal");
    expect(vm.auto_suspend == before);

    _ = raise(signalNumber(std.c.SIG.USR2));
    expect(vm.auto_suspend == before + 1);
    _ = ev.loop1() catch @panic("os_surface: the loop raised on a signal");
    expect(vm.auto_suspend == before);

    // The two handlers the callbacks scheduled run with the next fiber.
    harness.inFiber(env,
        \\(assert (= :plain (trampoline-hits 0)))
        \\(assert (= :interrupting (trampoline-hits 1)))
        \\(os/sigaction :usr1)
        \\(os/sigaction :usr2)
    );
}

/// `os/posix-fork` returns nil in the child and a `core/process` in the
/// parent. The child exits with `force` so that it does not flush the buffered
/// output the parent has already queued, which is what makes this safe to
/// run inside a contract at all.
///
/// The child's exit code is its own, 7. Were the two answers swapped, the
/// driver itself would take the child's branch and exit with 7, and the forked
/// copy's wait would find no child and see 0.
fn thePosixFork() void {
    const env: *tables.Table = harness.coreEnv();
    harness.inFiber(env,
        \\(def p (os/posix-fork))
        \\(if p
        \\  (do (assert (= :core/process (type p)))
        \\      (assert (pos? (p :pid)))
        \\      (assert (= 7 (os/proc-wait p))))
        \\  (os/exit 7 true))
    );
}

// ==========================================================================
// Entry
// ==========================================================================

/// One section, each in a VM of its own so that none inherits another's heap
/// or, for the two that sandbox themselves, another's sandbox.
fn section(comptime body: fn () void) void {
    harness.init();
    body();
    vm_lifecycle.deinit();
}

pub fn run() void {
    if (reduced_os) {
        // A reduced-OS build compiles four `os/` functions and none of this
        // file's subjects. The Janet suites cannot run against such a build at
        // all, `test/helper.janet` itself needing `os/getenv`, so the
        // library linking and the contracts passing is the whole of what that
        // configuration claims.
        std.debug.print("os_surface contract skipped (reduced OS)\n", .{});
        return;
    }

    section(theStatRead);
    section(theRegistration);
    section(theCalendar);
    section(thePermissions);
    section(theClock);
    section(theEnvironment);
    section(thePlatform);
    section(theOptionalArguments);
    // Each of these ends in a VM it opened itself; `section` closes that one.
    section(theOpenFlags);
    section(theRemoveSandbox);
    section(theLinks);
    section(thePipe);

    if (has_processes) {
        section(theProcessType);
        section(theSignalTable);
        section(theSpawnRedirection);
        section(theExecuteEnvironment);
        section(theSigaction);
        section(theTrampolines);
        section(thePosixFork);
    }
}
