//! Behavioral contract for the `os/` cfunction surface.
//!
//! `test/suite-os.janet` has fifty-eight assertions and every one of them is
//! about what an `os/` function returns. Four things about this subsystem are
//! invisible from there, and they are what this file is for.
//!
//! The registration *table* is the first. Its contents decide what exists, its
//! order is what `janet_nextmethod` walks, and its docstring and source-map
//! columns are what `(doc ...)` reads; a surface assembled from four files in
//! upstream's `os/` order can get every function right and the order wrong,
//! and no Janet assertion would notice. Upstream has one table literal and
//! `os.libOs` concatenates seven slices, so the order is newly a
//! thing that can break.
//!
//! The second is the stat reader. Janet sees only the values built on top of
//! it, so its contract -- the field indices, the zeroing of the slots no
//! platform writes, the -1 for a path that cannot be stat'ed -- has no
//! spelling on that side.
//!
//! The third is the `core/process` abstract type's shape: which of its
//! fourteen callbacks are null is a fact about the type rather than about any
//! process, and the value's own head is the only way to ask.
//!
//! The fourth is the signal table. `os_process.zig` holds the *names* and
//! reports a position; the surface holds the number each position carries on
//! this platform. Only the pair together produce a signal, and `os/proc-kill`
//! shows a caller nothing but "it worked" or "undefined signal".
//!
//! ## How the subjects are reached
//!
//! **The stat reader and the field registry are reached by import.** Both were
//! hand-declared symbols while a C caller needed them, and both ends were Zig
//! long before anything said so.
//!
//! **The source-map order check is unconditional.** It once ran only under a
//! bootstrap built from Zig, because a C bootstrap recorded a `.c` path for
//! every binding however the surface was compiled. Every source path in the
//! image is `src/`-relative, so the loop runs in every configuration.
//!
//! **A reduced-OS build is skipped rather than compiled away.** The subject is
//! still compiled in that configuration -- four `os/` functions of the
//! forty-odd below -- so the skip says which it is rather than pretending the
//! file does not exist.

const std = @import("std");
const builtin = @import("builtin");
const repr = @import("repr");
const harness = @import("harness.zig");

const subsystems = @import("subsystems");
const value = @import("subsystems").value;
const config = @import("config");
const structs = @import("subsystems").value.structs;
const tables = @import("subsystems").value.tables;
const strings = @import("subsystems").value.strings;
const utils = @import("subsystems").utils;
const wrap = @import("subsystems").value.wrap;
const args_core = @import("subsystems").args;
const vm_lifecycle = @import("subsystems").lifecycle;
const tuples = @import("subsystems").value.tuples;
const host_stat = subsystems.host_stat;
const os_stat = subsystems.stat;
const os_files = subsystems.os_files;

const expect = @import("expect.zig").expect;

const windows = builtin.os.tag == .windows;
const reduced_os = config.reduced_os;
const no_processes = !config.processes;
const no_locales = !config.locales;
const no_sourcemaps = !config.sourcemaps;
const no_docstrings = !config.docstrings;
const no_cryptorand = !config.cryptorand;

/// The two the surface itself reads, so that this file cannot disagree with
/// its subject about which entry points exist.
const no_umask = os_files.no_umask;
const no_symlinks = os_files.no_symlinks;

/// Whether the process functions are compiled *and* reachable. Every one of
/// them is POSIX-only in this contract's assertions.
const has_processes = !no_processes and !windows;

const scratch = "/tmp/janet-os-surface-contract";

// ==========================================================================
// The registration table
// ==========================================================================

/// Every `os/` binding this configuration must define, listed in the order
/// `os.libOs` registers them so that the list can be read beside the table. See `theRegistration` below for what is and is not asserted about
/// that order -- less than the listing suggests.
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

fn bindingField(env: *tables.Table, name: [*:0]const u8, field: [*:0]const u8) repr.Value {
    const binding = tables.get(env, value.fromBytes(std.mem.span(name), .symbol));
    if (harness.isType(binding, repr.Tag.table)) {
        return tables.get(wrap.toTable(binding), value.fromBytes(std.mem.span(field), .keyword));
    }
    if (harness.isType(binding, repr.Tag.@"struct")) {
        return structs.get(wrap.toStruct(binding), value.fromBytes(std.mem.span(field), .keyword));
    }
    return wrap.fromNil();
}

/// Registration *order* is not observable, and finding that out is worth
/// recording because the C contract first asserted that it was.
///
/// `os.libOs` puts its rows into the core environment, which is a hash
/// table, so nothing downstream can see which row came first. The source map
/// looked like a way to read the order back, and it is not: `JANET_CORE_FN`
/// records the line of the *definition* and `os.c` defined its cfunctions in a
/// wholly different order from the one it registered them in. Only
/// `corefn.reg` records the row, because `@src()` is valid only inside a
/// function and the row is where it is called.
///
/// So what is asserted here is the *set*, which catches a function dropped,
/// added, or duplicated -- a duplicate makes the list longer than the
/// environment.
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
        expect(harness.isType(binding, repr.Tag.table) or harness.isType(binding, repr.Tag.@"struct"));
        count += 1;

        // `corefn.reg` and `JANET_CORE_FN` both drop the source map when the
        // *bootstrap* was built without one, and the runtime arm always keeps
        // it. So the column exists in every configuration except
        // `-Dsourcemaps=false`, and asking for it there is asking for
        // something the build was told not to record. The matrix has that
        // entry, and this is what it found.
        if (!no_sourcemaps) {
            const smap = bindingField(env, name, "source-map");
            expect(harness.isType(smap, repr.Tag.tuple));
            const tuple = wrap.toTuple(smap);
            expect(tuples.head(tuple).length >= 2);
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

    // And nothing outside the list: every `os/` symbol the environment holds
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

// ==========================================================================
// The stat reader
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
    // `numbers` -- mode, and the two permission renderings built from it --
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
    if (!windows) {
        expect(numbers[Field.blocksize] > 0.0);
    } else {
        // The two slots no Windows stat has. They are zero because the array
        // is zeroed, not because anything wrote them.
        expect(numbers[Field.blocks] == 0.0);
        expect(numbers[Field.blocksize] == 0.0);
    }

    // A directory and a file differ in the mode word and in nothing this
    // function decides: the classification is the caller's.
    var directory_mode: u32 = 0;
    expect(host_stat.statRead("src/runtime", false, &directory_mode, &numbers) == 0);
    expect(directory_mode != mode);
}

// ==========================================================================
// The `core/process` type and the signal numbers
// ==========================================================================

/// Which callbacks the type supplies is a fact about the type. A process is
/// not marshallable, has no string rendering, and does not compare or hash --
/// so `(marshal p)` must fail and `(string p)` must fall back on the generic
/// abstract rendering. A port that filled one of those in by accident would
/// pass every suite.
fn theProcessType() void {
    const env: *tables.Table = harness.coreEnv();
    harness.inFiber(env,
        \\(def null (file/open "/dev/null" :w))
        \\# `/usr/bin/true` stood here and at one site below. Alpine is busybox
        \\# and puts it at `/bin/true`, so both spawns died with ENOENT the first
        \\# time this contract ran off macOS.
        \\# `/bin/sh` is already this file's dependency a dozen lines down and is
        \\# the one path every POSIX host agrees on.
        \\(def p (os/spawn ["/bin/sh" "-c" "exit 0"] :p {:out null :err null}))
        \\(def at (type p))
        \\(assert (= :core/process at))
        \\(assert (= 0 (os/proc-wait p)))
        \\(assert (not (first (protect (marshal p)))))
        \\(assert (string/has-prefix? "<core/process " (string p)))
        \\(assert (deep= @[:wait :kill :close :in :out :err] (keys p)))
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
/// writer to the pipe closes -- including a grandchild that outlived an
/// aborting contract. And the kill is *asserted* rather than merely performed,
/// so a mutated `os/proc-kill` that returns without killing fails an assertion
/// here rather than leaking a child that then holds the harness's pipe for its
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
        \\# `:vtalrm` is the spelling the table carries -- the signal's own
        \\# name with the `SIG` dropped -- and the transposition is not an
        \\# alias for it.
        \\(def q (sleeper))
        \\(assert (= "undefined signal :vtlarm"
        \\           (in (protect (os/proc-kill q false :vtlarm)) 1)))
        \\(assert (>= (os/proc-kill q true) 128))
        \\(file/close null)
    );
}

// ==========================================================================
// What the suites reach but do not assert
// ==========================================================================

/// The calendar's three functions, which `suite-os.janet` asserts nothing
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
        \\(assert (= 0 (os/mktime @{:year 1970 :month 0 :month-day 0})))
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
/// which `suite-os.janet` exercises none: a clock cannot be pinned to a value,
/// so the assertions are about the relationships between the formats instead.
fn theClock() void {
    const env: *tables.Table = harness.coreEnv();
    harness.inFiber(env,
        \\(each source [:realtime :monotonic :cputime]
        \\  (def d (os/clock source))
        \\  (def i (os/clock source :int))
        \\  (def t (os/clock source :tuple))
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
        \\(assert (= "expected :double, :int, or :tuple, got :bogus"
        \\           (in (protect (os/clock :realtime :bogus)) 1)))
    );
}

/// The environment lock is a no-op in every build this tree can produce, so
/// what is left to assert is the shape of what crosses it: `os/environ` must
/// preserve a value holding `=`, and an empty value is a value rather than an
/// absence.
fn theEnvironment() void {
    const env: *tables.Table = harness.coreEnv();
    harness.inFiber(env,
        \\(os/setenv "JANET_OS_SURFACE_A" "x=y=z")
        \\(assert (= "x=y=z" (os/getenv "JANET_OS_SURFACE_A")))
        \\(assert (= "x=y=z" (get (os/environ) "JANET_OS_SURFACE_A")))
        \\(os/setenv "JANET_OS_SURFACE_A" "")
        \\(assert (= "" (os/getenv "JANET_OS_SURFACE_A")))
        \\(assert (= "" (get (os/environ) "JANET_OS_SURFACE_A")))
        \\(os/setenv "JANET_OS_SURFACE_A")
        \\(assert (nil? (os/getenv "JANET_OS_SURFACE_A")))
        \\(assert (nil? (get (os/environ) "JANET_OS_SURFACE_A")))
        \\(assert (= :d (os/getenv "JANET_OS_SURFACE_A" :d)))
        \\(os/setenv "JANET_OS_SURFACE_A" "")
        \\(assert (= "" (os/getenv "JANET_OS_SURFACE_A" :d)))
        \\(os/setenv "JANET_OS_SURFACE_A")
    );
}

/// Platform introspection. The values are the host's, so the assertions are
/// about the shape of the answer and about `os/which`'s two modes, which no
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
        \\# The argument is a fallback, so the answer is the count where there is
        \\# one and the fallback where there is not -- and `(os/cpu-count)` with
        \\# no argument is exactly the test for which. `(= 7 (os/cpu-count 7))`
        \\# asserts the fallback as though it were the answer: true on macOS,
        \\# where the count has no arm at all and comes back -1, and false in a
        \\# Linux container, where the count is real. The form below holds on
        \\# both hosts and is the stronger claim on each.
        \\(assert (= (os/cpu-count 7) (or (os/cpu-count) 7)))
    );
}

// ==========================================================================
// What the first mutation sweep found missing
// ==========================================================================
//
// Everything above was written before that sweep and everything below after
// it. The split is worth keeping visible: the sweep left 135 survivors out of
// 302, and the great majority of the reachable ones were in three places the
// contract had not looked at -- `os/open`'s flag scanner, the optional-argument
// branches of half the surface, and the parts of `os/spawn` that only a
// redirection exercises. A contract written by reading the code finds what the
// code says; a sweep finds what the tests do not say.
//
// Files go under /tmp rather than the working directory, which is the other
// thing that sweep taught: a mutant left a mode-0000 `unique.txt` in the repo
// root and every later mutant was then "caught" by a suite that could not
// reopen it.

fn theOpenFlags() void {
    if (!harness.has_ev) return;
    var env: *tables.Table = harness.coreEnv();
    harness.inFiber(env,
        \\(os/mkdir "/tmp/janet-os-surface-contract")
        \\(defn p [n] (string "/tmp/janet-os-surface-contract/" n))
        \\(each n (os/dir "/tmp/janet-os-surface-contract") (os/rm (p n)))
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
    );
    vm_lifecycle.deinit();

    harness.init();
    env = harness.coreEnv();
    harness.inFiber(env,
        \\(defn p [n] (string "/tmp/janet-os-surface-contract/" n))
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
    );
}

/// `os/link`'s third argument decides between a hard link and a symbolic one,
/// and `os/symlink` is the same call with it forced true. Nothing above looked
/// at the argument at all.
fn theLinks() void {
    if (windows) return;
    const env: *tables.Table = harness.coreEnv();
    harness.inFiber(env,
        \\(protect (os/mkdir "/tmp/janet-os-surface-contract"))
        \\(defn p [n] (string "/tmp/janet-os-surface-contract/" n))
        \\(defn rm [n] (protect (os/rm (p n))))
        \\(rm "h") (rm "s") (rm "h2")
        \\(spit (p "tgt") "abc")
        \\(os/link (p "tgt") (p "h") false)
        \\(assert (= :file (os/lstat (p "h") :mode)))
        \\(assert (= 2 (os/stat (p "tgt") :nlink)))
        \\(os/link (p "tgt") (p "h2"))
        \\(assert (= :file (os/lstat (p "h2") :mode)))
        \\(assert (= 3 (os/stat (p "tgt") :nlink)))
        \\(os/link (p "tgt") (p "s") true)
        \\(assert (= :link (os/lstat (p "s") :mode)))
        \\(assert (= :file (os/stat (p "s") :mode)))
        \\(assert (= (p "tgt") (os/readlink (p "s"))))
        \\(rm "s")
        \\(os/symlink (p "tgt") (p "s"))
        \\(assert (= :link (os/lstat (p "s") :mode)))
        \\(each n (os/dir "/tmp/janet-os-surface-contract") (protect (os/rm (p n))))
        \\(os/rmdir "/tmp/janet-os-surface-contract")
    );
}

/// `os/rm` and the filesystem sandbox.
///
/// **Every filesystem entry point asserts the permission its operation needs**,
/// and `os/rm` and `os/readlink` are the two that once did not: `os/rm`
/// asserted nothing at all while its nine neighbours asserted `fs_write`, so a
/// sandboxed program could delete any file the process could reach, and
/// `os/readlink` asserted nothing where `os/stat`, `os/dir` and `os/realpath`
/// assert `fs_read`.
///
/// `sandbox` is irreversible within a VM, so this runs in a `janet_init` of
/// its own and does its setup before forbidding anything. The file it leaves
/// behind is cleaned by `theLinks`, which runs after it and removes the whole
/// scratch directory.
fn theRemoveSandbox() void {
    var env: *tables.Table = harness.coreEnv();
    harness.inFiber(env,
        \\(protect (os/mkdir "/tmp/janet-os-surface-contract"))
        \\(def victim (string "/tmp/janet-os-surface-contract/victim"))
        \\(spit victim "x")
        \\(assert (os/stat victim))
        \\(sandbox :fs-write)
        \\(assert (= "operation forbidden by sandbox"
        \\           (in (protect (os/rm victim)) 1)))
        \\(assert (os/stat victim) "the file survives a forbidden os/rm")
        \\(assert (= "operation forbidden by sandbox" (in (protect (os/rm)) 1)))
        \\(assert (= "operation forbidden by sandbox" (in (protect (os/rm 5)) 1)))
        \\(assert (= "operation forbidden by sandbox"
        \\           (in (protect (os/rmdir "/tmp/janet-os-surface-contract")) 1)))
    );
    vm_lifecycle.deinit();

    // A fresh VM, because the one above can never leave its sandbox. Without a
    // sandbox the delete still works, which is the half of the behaviour that
    // must not have changed.
    harness.init();
    env = harness.coreEnv();
    harness.inFiber(env,
        \\(def victim (string "/tmp/janet-os-surface-contract/victim"))
        \\(assert (os/stat victim))
        \\(os/rm victim)
        \\(assert (nil? (os/stat victim)))
        \\(spit victim "x")
        \\(sandbox :fs-read)
        \\(os/rm victim)
    );
}

/// The optional-argument branches. Each of these is an `argc >` or an
/// `argc ==` that decides whether a slot is read at all, and a mutation that
/// inverts one reads a slot that is not there or ignores one that is.
fn theOptionalArguments() void {
    const env: *tables.Table = harness.coreEnv();
    harness.inFiber(env,
        \\(assert (number? ((os/date) :year)))
        \\(assert (= (os/date) (os/date nil)))
        \\(assert (= (os/date 0) (os/date 0 nil)))
        \\# `(os/date t)` renders UTC and `(os/date t true)` renders local, so the
        \\# two differ only where the host's zone is not UTC. Asserting
        \\# `(not= ...)` unconditionally is a claim about the developer's machine
        \\# wearing the shape of a claim about the argument: it fails in a
        \\# container, where the zone *is* UTC and the two coincide. Both forms
        \\# below are portable and each is the stronger claim.
        \\#
        \\# The no-flag branch, pinned absolutely: epoch zero is
        \\# 1970-01-01T00:00:00 UTC on every host there is.
        \\(def epoch (os/date 0))
        \\(assert (= [1970 0 0 0 0 0]
        \\           [(epoch :year) (epoch :month) (epoch :month-day)
        \\            (epoch :hours) (epoch :minutes) (epoch :seconds)]))
        \\# The flag branch, cross-checked against the other renderer rather than
        \\# against itself: `os/strftime` reads the zone from the same place and
        \\# takes the same optional argument, so agreeing is a real claim on a
        \\# UTC host and on any other.
        \\(assert (= (scan-number (os/strftime "%H" 0 true)) ((os/date 0 true) :hours)))
        \\(assert (= (scan-number (os/strftime "%H" 0)) (epoch :hours)))
        \\(assert (string? (os/strftime "%Y")))
        \\(assert (= (os/strftime "%Y" 0) (os/strftime "%Y" 0 nil)))
        \\(def base {:year 1970 :month 0 :month-day 0})
        \\# The `:dst` slot is observable only in a zone that *has* a daylight
        \\# rule. `(not= ...)` against whatever zone the host happened to be in
        \\# is a claim about the developer's machine: it passes in JST and fails
        \\# in a container, where the zone is UTC and forcing DST changes
        \\# nothing.
        \\#
        \\# A POSIX TZ string supplies the rule without tzdata, so it is the same
        \\# zone on every host -- Alpine ships no zoneinfo and musl parses the
        \\# string natively, as does Darwin. That makes the difference exactly
        \\# one hour rather than merely non-zero, which is the stronger claim and
        \\# the one the slot is actually for.
        \\(def saved-tz (os/getenv "TZ"))
        \\(os/setenv "TZ" "EST5EDT,M3.2.0,M11.1.0")
        \\(assert (= 3600 (- (os/mktime (merge base {:dst false}) true)
        \\                   (os/mktime (merge base {:dst true}) true))))
        \\(assert (= 3600 (- (os/mktime (struct ;(kvs base) :dst false) true)
        \\                   (os/mktime (struct ;(kvs base) :dst true) true))))
        \\(assert (= (os/mktime base true)
        \\           (os/mktime (merge base {:dst false}) true)))
        \\(assert (= (os/mktime base true) (os/mktime (merge-into @{} base) true)))
        \\(assert (= (os/mktime (merge base {:dst true}) true)
        \\           (os/mktime (struct ;(kvs base) :dst true) true)))
        \\(if saved-tz (os/setenv "TZ" saved-tz) (os/setenv "TZ"))
        \\(assert (= (os/mktime base) (os/mktime base nil)))
        \\(assert (= "expected positive integer" (in (protect (os/cryptorand -1)) 1)))
    );

    if (!no_cryptorand) {
        harness.inFiber(env,
            \\(assert (= 4 (length (os/cryptorand 4))))
            \\(def b @"XY")
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

/// `os/spawn`'s redirections and flags. Everything here needs a subprocess
/// that actually produces output or an exit code, which is why none of it is
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
/// key holding `=` or NUL and keeps everything else, which is a rule
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
        \\# A handler is entered with no arguments, so one that cannot accept
        \\# zero can never run: no fiber can be built for it. The refusal is at
        \\# registration, where the caller can still act on it.
        \\(assert (string/has-prefix?
        \\           "signal handler must accept zero arguments"
        \\           (in (protect (os/sigaction :usr1 (fn [x] nil))) 1)))
        \\# A handler with an optional parameter still accepts zero.
        \\(os/sigaction :usr1 (fn [&opt x] nil))
        \\(os/sigaction :usr1 nil)
    );
}

/// `os/posix-fork` returns nil in the child and a `core/process` in the
/// parent. The child exits with `force` so that it does not flush the buffered
/// output the parent has already queued -- which is what makes this safe to
/// run inside a contract at all.
fn thePosixFork() void {
    const env: *tables.Table = harness.coreEnv();
    harness.inFiber(env,
        \\(def p (os/posix-fork))
        \\(if p
        \\  (do (assert (= :core/process (type p)))
        \\      (assert (int? (p :pid)))
        \\      (assert (= 0 (os/proc-wait p))))
        \\  (os/exit 0 true))
    );
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

// `os/exit`'s `force` argument is *not* tested here, and the reason is worth
// recording because the mutation sweep asks about it twice.
//
// `force` chooses `_Exit` over `exit`, and the only visible difference is
// whether the C library's buffered output is flushed on the way out. That can
// only be asked of a child process running a Janet snippet, and this contract
// has no interpreter to spawn: `(dyn :executable)` is the CLI's binding and
// `janet_core_env` does not set it, so a contract inside the runtime cannot
// name a janet binary. Forking and redirecting the child through a pipe would
// work and is more machinery than two mutants are worth.
//
// Both mutants therefore stand as deliberate survivors. The behaviour itself
// is real and was verified by hand: `(prin "x") (os/exit 0)` prints `x` and
// `(prin "x") (os/exit 0 true)` prints nothing.

/// One section, each in a VM of its own so that none inherits another's heap
/// -- or, for the two that sandbox themselves, another's sandbox.
fn section(comptime body: fn () void) void {
    harness.init();
    body();
    vm_lifecycle.deinit();
}

pub fn run() void {
    if (reduced_os) {
        // A reduced-OS build compiles four `os/` functions and none of this
        // file's subjects. The Janet suites cannot run against such a build at
        // all -- `test/helper.janet` itself needs `os/getenv` -- so the
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
        section(thePosixFork);
    }

    std.debug.print("os_surface contract ok\n", .{});
}
