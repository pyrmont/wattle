/* Behavioral contract for `os.c`'s cfunction surface, run against whichever
 * implementation the build selected (`-Dos-surface=c` or the Zig default).
 *
 * `test/suite-os.janet` has fifty-eight assertions and every one of them is
 * about what an `os/` function returns. Four things about this increment are
 * invisible from there, and they are what this file is for.
 *
 * The registration *table* is the first. Its contents decide what exists, its
 * order is what `janet_nextmethod` walks, and its docstring and source-map
 * columns are what `(doc ...)` reads; a surface assembled from four files in
 * `janet_lib_os`'s original order can get every function right and the order
 * wrong, and no Janet assertion would notice. `os.c` had one table literal and
 * the Zig surface concatenates seven slices, so the order is newly a thing
 * that can break.
 *
 * The second is `janet_zig_os_stat_read`, the one function left in `os.c`.
 * Janet sees only the values built on top of it, so its contract -- the field
 * indices, the zeroing of the slots no platform writes, the -1 for a path that
 * cannot be stat'ed -- has no spelling on that side.
 *
 * The third is the `core/process` abstract type's shape: which of its
 * fourteen callbacks are null is a fact about the type rather than about any
 * process, and `janet_abstract_type` is the only way to ask.
 *
 * The fourth is the signal table. `-Dos-process` holds the *names* and reports
 * a position; the surface holds the number each position carries on this
 * platform. Only the pair together produce a signal, and `os/proc-kill` shows
 * a caller nothing but "it worked" or "undefined signal". */

#include <assert.h>
#include <stdio.h>
#include <string.h>
#include <janet.h>

#ifndef JANET_REDUCED_OS

/* `os.c`'s remainder, compiled under both arms of `-Dos-surface` so that this
 * file can exercise it under both. A contract does not see the selector macro
 * -- the library module gets it and the contract module is a separate
 * translation unit -- which is a trap `test/vm_lifecycle.c` had already fallen
 * into: its `#ifdef JANET_ZIG_DEBUG_FRAMES` assertion had never been compiled
 * by any configuration. */
int32_t janet_zig_os_stat_read(const char *path, int32_t do_lstat,
                               uint32_t *mode, double *numbers);

int32_t janet_os_stat_field_count(void);
const char *janet_os_stat_field_name(int32_t index);
int32_t janet_os_stat_field_lookup(const uint8_t *key, int32_t len);

static void run(JanetTable *env, const char *source) {
    char wrapped[8192];
    int written = snprintf(wrapped, sizeof(wrapped), "(fn [] %s)", source);
    assert(written > 0 && written < (int) sizeof(wrapped));

    Janet fnv = janet_wrap_nil();
    assert(janet_dostring(env, wrapped, "os-surface-contract", &fnv) == 0);
    assert(janet_checktype(fnv, JANET_FUNCTION));

    JanetFiber *fiber = janet_fiber(janet_unwrap_function(fnv), 64, 0, NULL);
    fiber->env = env;
#ifdef JANET_EV
    janet_gcroot(janet_wrap_fiber(fiber));
    janet_schedule(fiber, janet_wrap_nil());
    janet_loop();
    assert(janet_fiber_status(fiber) == JANET_STATUS_DEAD);
    janet_gcunroot(janet_wrap_fiber(fiber));
#else
    Janet result = janet_wrap_nil();
    JanetSignal signal = janet_continue(fiber, janet_wrap_nil(), &result);
    if (signal != JANET_SIGNAL_OK) janet_stacktrace_ext(fiber, result, "");
    assert(signal == JANET_SIGNAL_OK);
#endif
}

/* ========================================================================
 * The registration table
 * ====================================================================== */

/* Every `os/` binding this configuration must define, listed in the order
 * `janet_lib_os` registers them so that the list can be read beside the
 * table. See `test_registration` below for what is and is not asserted about
 * that order -- less than the listing suggests. */
static const char *const expected_bindings[] = {
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
#ifndef JANET_NO_LOCALES
    "os/setlocale",
#endif
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
#ifndef JANET_NO_UMASK
    "os/umask",
#endif
#ifndef JANET_NO_SYMLINKS
    "os/readlink",
#endif
    "os/mkdir",
    "os/rmdir",
    "os/rm",
    "os/link",
    "os/rename",
#ifndef JANET_NO_SYMLINKS
    "os/symlink",
#endif
#ifndef JANET_NO_PROCESSES
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
#ifdef JANET_EV
    "os/sigaction",
#endif
#endif
    "os/clock",
#ifdef JANET_EV
    "os/open",
    "os/pipe",
#endif
    NULL
};

/* Registration *order* is not observable, and finding that out is worth
 * recording because this file first asserted that it was.
 *
 * `janet_lib_os` puts its rows into the core environment, which is a hash
 * table, so nothing downstream can see which row came first. The source map
 * looked like a way to read the order back, and it is not: `JANET_CORE_FN`
 * records the line of the *definition* and `os.c` defines its cfunctions in a
 * wholly different order from the one it registers them in -- `os/which` is
 * defined at line 264 and registered second, `os/exit` at 323 and registered
 * first. Only `corefn.reg` records the row, because `@src()` is valid only
 * inside a function and the row is where it is called.
 *
 * So what is asserted here is the *set*, in both arms, which catches a
 * function dropped, added, or duplicated -- a duplicate makes the list longer
 * than the environment.
 *
 * The order check that follows is narrower still, and the narrowing is worth
 * stating exactly. It compares source-map lines only where two consecutive
 * names come from the same `src/zig/` file, so it catches two rows exchanged
 * within one file and nothing across files. And it only *runs* under
 * `-Dboot=zig`: the source map a binding carries comes from the image, the
 * image is built by whichever generator `-Dboot` selects, and the C generator
 * records `src/core/os.c` for every one of these however the surface is
 * compiled. Under the default `-Dboot=c` this loop is a presence check and
 * says so by skipping. That is what makes the matrix's `-Dboot=zig` entry
 * load-bearing for this increment rather than inherited. */
static Janet binding_field(JanetTable *env, const char *name, const char *field) {
    Janet binding = janet_table_get(env, janet_csymbolv(name));
    if (janet_checktype(binding, JANET_TABLE)) {
        return janet_table_get(janet_unwrap_table(binding), janet_ckeywordv(field));
    }
    if (janet_checktype(binding, JANET_STRUCT)) {
        return janet_struct_get(janet_unwrap_struct(binding), janet_ckeywordv(field));
    }
    return janet_wrap_nil();
}

static void test_registration(void) {
    JanetTable *env = janet_core_env(NULL);
    int32_t count = 0;
#ifndef JANET_NO_SOURCEMAPS
    const uint8_t *prev_file = NULL;
    int32_t prev_line = -1;
#endif

    for (const char *const *name = expected_bindings; *name != NULL; name++) {
        Janet binding = janet_table_get(env, janet_csymbolv(*name));
        assert(!janet_checktype(binding, JANET_NIL));
        assert(janet_checktype(binding, JANET_TABLE) ||
               janet_checktype(binding, JANET_STRUCT));
        count++;

        /* `corefn.reg` and `JANET_CORE_FN` both drop the source map when the
         * *bootstrap* was built without one, and the runtime arm always keeps
         * it. So the column exists in every configuration except
         * `-Dboot=zig -Dsourcemaps=false` and `-Dboot=c -Dsourcemaps=false`,
         * and asking for it there is asking for something the build was told
         * not to record. The matrix has both of those entries, and this is
         * what they found. */
#ifndef JANET_NO_SOURCEMAPS
        Janet smap = binding_field(env, *name, "source-map");
        assert(janet_checktype(smap, JANET_TUPLE));
        const Janet *tup = janet_unwrap_tuple(smap);
        assert(janet_tuple_length(tup) >= 2);
        assert(janet_checktype(tup[0], JANET_STRING));
        assert(janet_checkint(tup[1]));
        {
            const uint8_t *file = janet_unwrap_string(tup[0]);
            int32_t line = janet_unwrap_integer(tup[1]);
            /* Which implementation registered this is read from the path
             * rather than from a macro, because a contract cannot see the
             * selector. The Zig path is repo-relative, which is what
             * `corefn.sourcePath` builds; the C one is absolute, which is the
             * defect Part 6 recorded and did not fix. */
            int from_zig = janet_string_length(file) > 8 &&
                           memcmp(file, "src/zig/", 8) == 0;
            if (from_zig && prev_file != NULL &&
                    janet_string_equal(prev_file, file)) {
                assert(line > prev_line);
            }
            prev_file = file;
            prev_line = line;
        }
#endif /* JANET_NO_SOURCEMAPS */
    }

    /* And nothing outside the list: every `os/` symbol the environment holds
     * has to be one this file named. A function added to the surface and left
     * out of `expected_bindings` fails here rather than silently, and a name
     * listed twice makes `count` exceed `found`. */
    int32_t found = 0;
    for (int32_t i = 0; i < env->capacity; i++) {
        Janet key = env->data[i].key;
        if (!janet_checktype(key, JANET_SYMBOL)) continue;
        const uint8_t *sym = janet_unwrap_symbol(key);
        if (janet_string_length(sym) < 3) continue;
        if (memcmp(sym, "os/", 3) != 0) continue;
        found++;
        int matched = 0;
        for (const char *const *name = expected_bindings; *name != NULL; name++) {
            if (janet_cstrcmp(sym, *name) == 0) matched = 1;
        }
        assert(matched);
    }
    assert(found == count);

    /* The docstring is `corefn.reg`'s other column, and a row that lost it
     * still registers a working function. Both generators drop it under
     * `-Ddocstrings=false`, so the assertion follows the flag. */
#ifndef JANET_NO_DOCSTRINGS
    run(env,
        "(assert (string? ((dyn 'os/stat) :doc)))\n"
        "(assert (string/has-prefix? \"(os/stat path\" ((dyn 'os/stat) :doc)))\n"
#ifndef JANET_NO_PROCESSES
        "(assert (string? ((dyn 'os/spawn) :doc)))\n"
#endif
        "(assert (string? ((dyn 'os/date) :doc)))\n");
#else
    (void) run;
#endif
}

/* ========================================================================
 * The one function left in `os.c`
 * ====================================================================== */

/* The field identifiers, restated here so that a renumbering on either side
 * fails against a third copy rather than agreeing with itself. `-Dos-stat`'s
 * registry lists the same names in the same order and `test/os_stat.c` pins
 * that; this pins the *numbers* the stat reader writes at. */
enum {
    F_DEV, F_INODE, F_MODE, F_INT_PERMISSIONS, F_PERMISSIONS,
    F_UID, F_GID, F_NLINK, F_RDEV, F_SIZE,
    F_BLOCKS, F_BLOCKSIZE, F_ACCESSED, F_MODIFIED, F_CHANGED,
    F_COUNT
};

static void test_stat_read(void) {
    assert(janet_os_stat_field_count() == F_COUNT);
    assert(strcmp("dev", janet_os_stat_field_name(F_DEV)) == 0);
    assert(strcmp("size", janet_os_stat_field_name(F_SIZE)) == 0);
    assert(strcmp("changed", janet_os_stat_field_name(F_CHANGED)) == 0);

    /* A path that cannot be stat'ed reports -1 and is the only failure this
     * reports at all; `errno` is not consulted by the caller. */
    uint32_t mode = 0xABCD;
    double numbers[F_COUNT];
    for (int32_t i = 0; i < F_COUNT; i++) numbers[i] = -12345.0;
    assert(janet_zig_os_stat_read("no/such/path/xyz", 0, &mode, numbers) == -1);
    /* Nothing is written on failure, including the mode. */
    assert(mode == 0xABCD);
    assert(numbers[F_SIZE] == -12345.0);

    /* A real path fills every slot. The three the caller never reads through
     * `numbers` -- mode, and the two permission renderings built from it --
     * are zero rather than indeterminate, which is the contract Part 5's
     * lesson asks for: "a descriptor's unwritten fields are part of its
     * contract and nothing about the type says so". */
    /* Any file this repository certainly has. It was `src/core/os.c` until
     * Phase 10 Part 18 deleted every `.c` under `src/`. */
    assert(janet_zig_os_stat_read("src/include/janet.h", 0, &mode, numbers) == 0);
    assert(mode != 0);
    assert(numbers[F_MODE] == 0.0);
    assert(numbers[F_INT_PERMISSIONS] == 0.0);
    assert(numbers[F_PERMISSIONS] == 0.0);
    assert(numbers[F_SIZE] > 0.0);
    assert(numbers[F_NLINK] >= 1.0);
    assert(numbers[F_INODE] > 0.0);
    assert(numbers[F_MODIFIED] > 0.0);
#ifndef JANET_WINDOWS
    assert(numbers[F_BLOCKSIZE] > 0.0);
#else
    /* The two slots no Windows stat has. They are zero because the array is
     * zeroed, not because anything wrote them. */
    assert(numbers[F_BLOCKS] == 0.0);
    assert(numbers[F_BLOCKSIZE] == 0.0);
#endif

    /* A directory and a file differ in the mode word and in nothing this
     * function decides: the classification is `-Dos-stat`'s. */
    uint32_t dir_mode = 0;
    assert(janet_zig_os_stat_read("src/core", 0, &dir_mode, numbers) == 0);
    assert(dir_mode != mode);
}

/* ========================================================================
 * The `core/process` type
 * ====================================================================== */

#if !defined(JANET_NO_PROCESSES) && !defined(JANET_WINDOWS)

/* Which callbacks the type supplies is a fact about the type. A process is
 * not marshallable, has no string rendering, and does not compare or hash --
 * so `(marshal p)` must fail and `(string p)` must fall back on the generic
 * abstract rendering. A port that filled one of those in by accident would
 * pass every suite. */
static void test_proc_type(void) {
    JanetTable *env = janet_core_env(NULL);
    run(env,
        "(def null (file/open \"/dev/null\" :w))\n"
        "(def p (os/spawn [\"/usr/bin/true\"] :p {:out null :err null}))\n"
        "(def at (type p))\n"
        "(assert (= :core/process at))\n"
        "(assert (= 0 (os/proc-wait p)))\n"
        /* No marshal callback: an unregistered abstract cannot be written. */
        "(assert (not (first (protect (marshal p)))))\n"
        /* No tostring callback: the generic `<core/process 0x...>` form. */
        "(assert (string/has-prefix? \"<core/process \" (string p)))\n"
        /* `next` walks the method table linearly, so `(keys p)` reports the
         * table's *order*, not a sorted set. Three real methods, then the
         * three dud entries that exist only so that `:in`, `:out` and `:err`
         * appear here at all. */
        "(assert (deep= @[:wait :kill :close :in :out :err] (keys p)))\n"
        "(file/close null)\n");
}

/* The signal table: a name the platform defines resolves, and one it does not
 * reports "undefined signal" with the keyword in the message. Which of the
 * twenty-eight fall on each side is a platform fact, so the assertion is about
 * the two behaviours rather than about a fixed list -- except for the ones ISO
 * C guarantees, which every platform has.
 *
 * Two details here are about the *sweep* rather than about signals, and both
 * were forced by a false-catch channel Phase 10 Part 12 found in its own
 * mutation run.
 *
 * A child is given an explicit stdout and stderr instead of inheriting this
 * process's. `mutate.py` runs a contract with `capture_output=True`, which
 * blocks until every writer to the pipe closes -- including a grandchild that
 * outlived an aborting contract. A `/bin/sleep 30` orphan therefore held the
 * pipe for the harness's whole twenty-second bound, and the mutant was scored
 * "contract (hang)" whatever the contract had actually decided.
 *
 * And the kill is *asserted* rather than merely performed. A signal that
 * terminates a process makes Janet report 128 plus its number, so a mutated
 * `os/proc-kill` that returns without killing now fails an assertion here.
 * Before, it left seven orphans, the contract passed, the harness timed out on
 * the pipe, and the mutant was recorded as caught by a test that had not
 * caught it -- which is Part 8's lesson about labelling the catcher, arriving
 * from the other direction. */
static void test_signal_table(void) {
    JanetTable *env = janet_core_env(NULL);
    run(env,
        "(def null (file/open \"/dev/null\" :w))\n"
        "(defn sleeper [] (os/spawn [\"/bin/sleep\" \"30\"] :p {:out null :err null}))\n"
        /* The subject here is the *table* -- whether a keyword resolves to a
         * number -- so that is what is asserted, and nothing depends on what
         * the signal then does to the child.
         *
         * That distinction is not fastidiousness. Sending a signal and
         * checking that the child died makes the test depend on the child's
         * *disposition* for that signal, and an ignored disposition is
         * inherited across fork and exec. This contract runs under
         * `mutate.py`, which the sweep launches with `nohup`; `nohup` ignores
         * SIGHUP, `/bin/sleep` inherits that, and `(os/proc-kill p true :hup)`
         * then waits forever. Two sweeps aborted in their warm-up before that
         * was understood, and it never reproduced interactively because an
         * interactive shell does not ignore SIGHUP. SIGKILL is the one signal
         * that cannot be caught or ignored, so it is the one the death
         * assertion uses.
         *
         * The catch-all `:kill` at the end of each iteration is also what
         * makes a mutated `os/proc-kill` fail an assertion rather than leak a
         * child -- see the note above about orphans holding the harness's
         * captured pipe. */
        "(each sig [:int :term :hup :usr1 :usr2 :alrm :chld :cont]\n"
        "  (def p (sleeper))\n"
        "  (def res (protect (os/proc-kill p false sig)))\n"
        "  (assert (first res) (string \"signal \" sig \" resolves to a number\"))\n"
        "  (assert (>= (os/proc-kill p true :kill) 128)\n"
        "          (string \"the child of \" sig \" is killed\")))\n"
        /* SIGKILL by itself, which is the default and cannot be ignored. */
        "(def k (sleeper))\n"
        "(assert (= 137 (os/proc-kill k true :kill)))\n"
        "(def d (sleeper))\n"
        "(assert (= 137 (os/proc-kill d true)))\n"
        /* A keyword the name list does not hold. */
        "(def p (sleeper))\n"
        "(assert (= \"undefined signal :nosuchsignal\"\n"
        "           (in (protect (os/proc-kill p false :nosuchsignal)) 1)))\n"
        "(assert (>= (os/proc-kill p true) 128))\n"
        /* FOUND.md: the keyword for SIGVTALRM is misspelled, so the documented
         * name is undefined and the misspelling is what resolves. Reproduced
         * rather than repaired, and pinned here so a tidy-up fails. */
        "(def q (sleeper))\n"
        "(assert (= \"undefined signal :vtalrm\"\n"
        "           (in (protect (os/proc-kill q false :vtalrm)) 1)))\n"
        "(assert (>= (os/proc-kill q true) 128))\n"
        "(file/close null)\n");
}

#endif /* !JANET_NO_PROCESSES && !JANET_WINDOWS */

/* ========================================================================
 * What the suites reach but do not assert
 * ====================================================================== */

/* The calendar's three functions are the second area Phase 10's decision 4
 * unparks, and `suite-os.janet` asserts nothing about any of them. Fixed
 * timestamps rather than the current time, because the current time agrees
 * with itself whatever it computes. */
static void test_calendar(void) {
    JanetTable *env = janet_core_env(NULL);
    run(env,
        /* The epoch, in UTC, field by field. */
        "(def d (os/date 0))\n"
        "(assert (= 1970 (d :year)))\n"
        "(assert (= 0 (d :month)))\n"
        "(assert (= 0 (d :month-day)))\n"
        "(assert (= 4 (d :week-day)))\n"
        "(assert (= 0 (d :year-day)))\n"
        "(assert (= false (d :dst)))\n"
        /* `:month-day` is 0-indexed and `:month` is too, which is what the
         * `- 1` and the `+ 1` in the two directions are for. */
        "(def d2 (os/date 1600000000))\n"
        "(assert (= 2020 (d2 :year)))\n"
        "(assert (= 8 (d2 :month)))\n"
        "(assert (= 12 (d2 :month-day)))\n"
        "(assert (= 1600000000 (os/mktime d2)))\n"
        /* A missing field is zero, and `:month-day` zero means the first. */
        "(assert (= 0 (os/mktime {:year 1970 :month 0 :month-day 0})))\n"
        "(assert (= 86400 (os/mktime {:year 1970 :month 0 :month-day 1})))\n"
        /* A table and a struct are both accepted; anything else is a type
         * fault from the argument layer rather than a message of its own. */
        "(assert (= 0 (os/mktime @{:year 1970 :month 0 :month-day 0})))\n"
        "(assert (not (first (protect (os/mktime 5)))))\n"
        "(assert (not (first (protect (os/mktime {:year \"x\"})))))\n"
        /* strftime validates its specifiers before it reads the clock, so a
         * bad one is reported whatever the time argument is. */
        "(assert (= \"1970-01-01T00:00:00\" (os/strftime \"%Y-%m-%dT%H:%M:%S\" 0)))\n"
        "(assert (= \"100%\" (os/strftime \"100%%\" 0)))\n"
        "(assert (= \"\" (os/strftime \"\" 0)))\n"
        "(assert (= \"invalid conversion specifier '%Q'\"\n"
        "           (in (protect (os/strftime \"%Q\" 0)) 1)))\n"
        "(assert (= \"invalid conversion specifier\"\n"
        "           (in (protect (os/strftime \"abc%\" 0)) 1)))\n");
}

/* The permission conversions have a fault message per slot, and the slot
 * number is part of it. `-Dargs-core`'s layer builds most of Janet's argument
 * messages; these two are the surface's own. */
static void test_permissions(void) {
    JanetTable *env = janet_core_env(NULL);
    run(env,
        "(assert (= \"rwxr-xr-x\" (os/perm-string 8r755)))\n"
        "(assert (= \"---------\" (os/perm-string 0)))\n"
        "(assert (= 8r755 (os/perm-int \"rwxr-xr-x\")))\n"
        /* Every value round trips, which is what makes the two conversions
         * each other's inverse rather than merely agreeing on the cases a
         * suite happens to list. */
        "(for i 0 8r1000 (assert (= i (os/perm-int (os/perm-string i)))))\n"
        /* The slot number is in the message, and it is the argument index. */
        "(assert (= \"bad slot #0, expected integer in range [0, 8r777], got 512\"\n"
        "           (in (protect (os/perm-string 8r1000)) 1)))\n"
        "(assert (= \"bad slot #0: expected byte sequence of length 9, got \\\"rwx\\\"\"\n"
        "           (in (protect (os/perm-int \"rwx\")) 1)))\n"
        /* A negative integer is out of range rather than a byte view. */
        "(assert (not (first (protect (os/perm-string -1)))))\n");
}

/* `os/clock`'s three sources and three formats are nine combinations, of which
 * `suite-os.janet` exercises none: a clock cannot be pinned to a value, so the
 * assertions are about the relationships between the formats instead. */
static void test_clock(void) {
    JanetTable *env = janet_core_env(NULL);
    run(env,
        "(each source [:realtime :monotonic :cputime]\n"
        "  (def d (os/clock source))\n"
        "  (def i (os/clock source :int))\n"
        "  (def t (os/clock source :tuple))\n"
        "  (assert (number? d))\n"
        "  (assert (= i (math/floor i)))\n"
        "  (assert (= 2 (length t)))\n"
        /* The nanosecond half is a nanosecond count, not a fraction. */
        "  (assert (and (<= 0 (in t 1)) (< (in t 1) 1000000000))))\n"
        /* The default source is :realtime and the default format :double. */
        "(assert (< (math/abs (- (os/clock) (os/clock :realtime))) 1))\n"
        "(assert (< (math/abs (- (os/time) (os/clock :realtime :int))) 2))\n"
        /* Monotonic does not go backwards across a sleep, and does advance. */
        "(def before (os/clock :monotonic))\n"
        "(os/sleep 0.01)\n"
        "(assert (> (os/clock :monotonic) before))\n"
        "(assert (= \"expected :realtime, :monotonic, or :cputime, got :bogus\"\n"
        "           (in (protect (os/clock :bogus)) 1)))\n"
        "(assert (= \"expected :double, :int, or :tuple, got :bogus\"\n"
        "           (in (protect (os/clock :realtime :bogus)) 1)))\n");
}

/* The environment lock is a no-op in every build this tree can produce, so
 * what is left to assert is the shape of what crosses it: `os/environ` must
 * preserve a value holding `=`, and an empty value is a value rather than an
 * absence. */
static void test_environment(void) {
    JanetTable *env = janet_core_env(NULL);
    run(env,
        "(os/setenv \"JANET_OS_SURFACE_A\" \"x=y=z\")\n"
        "(assert (= \"x=y=z\" (os/getenv \"JANET_OS_SURFACE_A\")))\n"
        "(assert (= \"x=y=z\" (get (os/environ) \"JANET_OS_SURFACE_A\")))\n"
        "(os/setenv \"JANET_OS_SURFACE_A\" \"\")\n"
        "(assert (= \"\" (os/getenv \"JANET_OS_SURFACE_A\")))\n"
        "(assert (= \"\" (get (os/environ) \"JANET_OS_SURFACE_A\")))\n"
        /* One argument unsets, which the arity allows and the docstring does
         * not mention. */
        "(os/setenv \"JANET_OS_SURFACE_A\")\n"
        "(assert (nil? (os/getenv \"JANET_OS_SURFACE_A\")))\n"
        "(assert (nil? (get (os/environ) \"JANET_OS_SURFACE_A\")))\n"
        /* The default is returned only when the variable is absent, not when
         * it is empty. */
        "(assert (= :d (os/getenv \"JANET_OS_SURFACE_A\" :d)))\n"
        "(os/setenv \"JANET_OS_SURFACE_A\" \"\")\n"
        "(assert (= \"\" (os/getenv \"JANET_OS_SURFACE_A\" :d)))\n"
        "(os/setenv \"JANET_OS_SURFACE_A\")\n");
}

/* Platform introspection. The values are the host's, so the assertions are
 * about the shape of the answer and about `os/which`'s two modes, which no
 * suite exercises. */
static void test_platform(void) {
    JanetTable *env = janet_core_env(NULL);
    run(env,
        "(assert (keyword? (os/which)))\n"
        "(assert (keyword? (os/arch)))\n"
        "(assert (keyword? (os/compiler)))\n"
        /* With a truthy argument it compares instead of reporting. */
        "(assert (= true (os/which (os/which))))\n"
        "(assert (= false (os/which :definitely-not-an-os)))\n"
        /* nil and false both mean \"report\", not \"compare with nil\". */
        "(assert (keyword? (os/which nil)))\n"
        "(assert (keyword? (os/which false)))\n"
        /* The argument is constrained to keywords even though only equality is
         * asked of it. */
        "(assert (not (first (protect (os/which \"linux\")))))\n"
        "(assert (or (nil? (os/cpu-count)) (pos? (os/cpu-count))))\n"
        "(assert (= 7 (os/cpu-count 7)) )\n");
}

/* ========================================================================
 * What the first mutation sweep found missing
 * ======================================================================
 *
 * Everything above was written before the sweep and everything below after
 * it. The split is worth keeping visible: the sweep left 135 survivors out of
 * 302, and the great majority of the reachable ones were in three places this
 * file had not looked at -- `os/open`'s flag scanner, the optional-argument
 * branches of half the surface, and the parts of `os/spawn` that only a
 * redirection exercises. A contract written by reading the code finds what the
 * code says; a sweep finds what the tests do not say.
 *
 * Files go under /tmp rather than the working directory, which is the other
 * thing that sweep taught: a mutant left a mode-0000 `unique.txt` in the repo
 * root and every later mutant was then "caught" by a suite that could not
 * reopen it. */

#define SCRATCH "/tmp/janet-os-surface-contract"

static void test_open_flags(void) {
#ifdef JANET_EV
    JanetTable *env = janet_core_env(NULL);
    run(env,
        "(os/mkdir \"" SCRATCH "\")\n"
        "(defn p [n] (string \"" SCRATCH "/\" n))\n"
        "(each n (os/dir \"" SCRATCH "\") (os/rm (p n)))\n"
        "(spit (p \"ro\") \"abc\") (os/chmod (p \"ro\") 8r444)\n"
        "(spit (p \"wo\") \"abc\") (os/chmod (p \"wo\") 8r222)\n"
        "(spit (p \"rw\") \"abc\") (os/chmod (p \"rw\") 8r644)\n"
        /* `:r` must open read-only, not read-write: a file with no write
         * permission cannot be opened O_RDWR, so the three-way fixup at the
         * end of the scanner is load-bearing and this is what pins it. */
        "(def s (os/open (p \"ro\") :r))\n"
        "(assert (= \"abc\" (string (:read s 3))))\n"
        "(assert (= \"bad stream, expected writable stream\"\n"
        "           (in (protect (:write s \"z\")) 1)))\n"
        "(:close s)\n"
        /* And `:w` must open write-only, for the mirror reason. */
        "(def s2 (os/open (p \"wo\") :w))\n"
        "(:write s2 \"z\")\n"
        "(assert (= \"bad stream, expected readable stream\"\n"
        "           (in (protect (:read s2 1)) 1)))\n"
        "(:close s2)\n"
        /* Both flags, and neither, are O_RDWR. */
        "(def s3 (os/open (p \"rw\") :rw))\n"
        "(:write s3 \"Q\")\n"
        "(:close s3)\n"
        "(assert (= \"Qbc\" (string (slurp (p \"rw\")))))\n");
    janet_deinit();

    janet_init();
    env = janet_core_env(NULL);
    run(env,
        "(defn p [n] (string \"" SCRATCH "/\" n))\n"
        /* `:N` turns off O_NONBLOCK *and* the stream's own readable and
         * writable flags, so the handle it returns can do neither. */
        "(def s (os/open (p \"rw\") :rN))\n"
        "(assert (= \"bad stream, expected readable stream\"\n"
        "           (in (protect (:read s 1)) 1)))\n"
        "(:close s)\n"
        /* `:a` appends rather than truncating; `:t` truncates. */
        "(spit (p \"ap\") \"1\")\n"
        "(def a (os/open (p \"ap\") :wa)) (:write a \"2\") (:close a)\n"
        "(assert (= \"12\" (string (slurp (p \"ap\")))))\n"
        "(spit (p \"tr\") \"xyz\")\n"
        "(:close (os/open (p \"tr\") :wt))\n"
        "(assert (= 0 (length (slurp (p \"tr\")))))\n"
        /* `:c` creates, `:e` refuses to create over an existing file. */
        "(:close (os/open (p \"ce\") :wce))\n"
        "(assert (= \"File exists\" (in (protect (os/open (p \"ce\") :wce)) 1)))\n"
        /* The third argument is a mode, and it is only consulted when the
         * file is created. 8r640 has no bit a default umask would clear. */
        "(:close (os/open (p \"md\") :wc 8r640))\n"
        "(assert (= \"rw-r-----\" (os/stat (p \"md\") :permissions)))\n"
        /* An unknown flag letter is ignored rather than rejected. */
        "(def z (os/open (p \"rw\") :rZ)) (:close z)\n");
#endif
}

/* `os/link`'s third argument decides between a hard link and a symbolic one,
 * and `os/symlink` is the same call with it forced true. Nothing above looked
 * at the argument at all. */
static void test_links(void) {
#ifndef JANET_WINDOWS
    JanetTable *env = janet_core_env(NULL);
    run(env,
        /* Made here rather than inherited from `test_open_flags`, which is
         * EV-only: a `-Dev=false` build runs this one and not that one. */
        "(protect (os/mkdir \"" SCRATCH "\"))\n"
        "(defn p [n] (string \"" SCRATCH "/\" n))\n"
        "(defn rm [n] (protect (os/rm (p n))))\n"
        "(rm \"h\") (rm \"s\") (rm \"h2\")\n"
        "(spit (p \"tgt\") \"abc\")\n"
        /* Falsey and absent both mean a hard link: same inode, and the
         * target's link count goes up. */
        "(os/link (p \"tgt\") (p \"h\") false)\n"
        "(assert (= :file (os/lstat (p \"h\") :mode)))\n"
        "(assert (= 2 (os/stat (p \"tgt\") :nlink)))\n"
        "(os/link (p \"tgt\") (p \"h2\"))\n"
        "(assert (= :file (os/lstat (p \"h2\") :mode)))\n"
        "(assert (= 3 (os/stat (p \"tgt\") :nlink)))\n"
        /* Truthy means a symbolic link, which `os/lstat` reports as :link and
         * `os/stat` follows. */
        "(os/link (p \"tgt\") (p \"s\") true)\n"
        "(assert (= :link (os/lstat (p \"s\") :mode)))\n"
        "(assert (= :file (os/stat (p \"s\") :mode)))\n"
        "(assert (= (p \"tgt\") (os/readlink (p \"s\"))))\n"
        "(rm \"s\")\n"
        "(os/symlink (p \"tgt\") (p \"s\"))\n"
        "(assert (= :link (os/lstat (p \"s\") :mode)))\n"
        "(each n (os/dir \"" SCRATCH "\") (protect (os/rm (p n))))\n"
        "(os/rmdir \"" SCRATCH "\")\n");
#endif
}

/* `os/rm` and the filesystem sandbox.
 *
 * This is the one place the port deliberately departs from the C original's
 * behaviour, by agreement rather than by rule: `os.c` asserted no permission
 * in `os/rm` while asserting `JANET_SANDBOX_FS_WRITE` in every one of its
 * neighbours, so a sandboxed program could delete any file the process could
 * reach. `FOUND.md` keeps the entry for reporting upstream and both
 * implementations carry the fix, which is why this can be asserted here rather
 * than only against one arm.
 *
 * `sandbox` is irreversible within a VM, so this runs in a `janet_init` of its
 * own and does its setup before forbidding anything. The file it leaves behind
 * is cleaned by `test_links`, which runs after it and removes the whole
 * scratch directory. */
static void test_rm_sandbox(void) {
    JanetTable *env = janet_core_env(NULL);
    run(env,
        "(protect (os/mkdir \"" SCRATCH "\"))\n"
        "(def victim (string \"" SCRATCH "/victim\"))\n"
        "(spit victim \"x\")\n"
        "(assert (os/stat victim))\n"
        /* Forbidding writes must now stop the delete, and the file must still
         * be there afterwards -- the assertion has to outlive the message,
         * because a raise that happened after the `remove` would look the
         * same from the outside. */
        "(sandbox :fs-write)\n"
        "(assert (= \"operation forbidden by sandbox\"\n"
        "           (in (protect (os/rm victim)) 1)))\n"
        "(assert (os/stat victim) \"the file survives a forbidden os/rm\")\n"
        /* The assertion comes before the arity and type checks, which is the
         * order every other filesystem mutation in `os.c` uses and is
         * observable. */
        "(assert (= \"operation forbidden by sandbox\" (in (protect (os/rm)) 1)))\n"
        "(assert (= \"operation forbidden by sandbox\" (in (protect (os/rm 5)) 1)))\n"
        /* And it is the same permission its neighbours ask for. */
        "(assert (= \"operation forbidden by sandbox\"\n"
        "           (in (protect (os/rmdir \"" SCRATCH "\")) 1)))\n");
    janet_deinit();

    /* A fresh VM, because the one above can never leave its sandbox. Without
     * a sandbox the delete still works, which is the half of the behaviour
     * that must not have changed. */
    janet_init();
    env = janet_core_env(NULL);
    run(env,
        "(def victim (string \"" SCRATCH "/victim\"))\n"
        "(assert (os/stat victim))\n"
        "(os/rm victim)\n"
        "(assert (nil? (os/stat victim)))\n"
        /* `:fs-read` is a different permission and does not forbid a delete,
         * exactly as it does not forbid `os/rmdir`. */
        "(spit victim \"x\")\n"
        "(sandbox :fs-read)\n"
        "(os/rm victim)\n");
}

/* The optional-argument branches. Each of these is an `argc >` or an
 * `argc ==` that decides whether a slot is read at all, and a mutation that
 * inverts one reads a slot that is not there or ignores one that is. */
static void test_optional_arguments(void) {
    JanetTable *env = janet_core_env(NULL);
    run(env,
        /* `os/date` and `os/strftime` take the timestamp at different
         * positions, and nil means "now" in both. */
        "(assert (number? ((os/date) :year)))\n"
        "(assert (= (os/date) (os/date nil)))\n"
        "(assert (= (os/date 0) (os/date 0 nil)))\n"
        "(assert (not= (os/date 0) (os/date 0 true)) )\n"
        "(assert (string? (os/strftime \"%Y\")))\n"
        "(assert (= (os/strftime \"%Y\" 0) (os/strftime \"%Y\" 0 nil)))\n"
        /* `:dst` is three-valued: true, false, and absent, and absent is not
         * false -- it is `tm_isdst = -1`, "work it out". */
        "(def base {:year 1970 :month 0 :month-day 0})\n"
        "(assert (not= (os/mktime (merge base {:dst true}) true)\n"
        "              (os/mktime (merge base {:dst false}) true)))\n"
        "(assert (= (os/mktime base true)\n"
        "           (os/mktime (merge base {:dst false}) true)))\n"
        /* A table and a struct read the same, and each reads `:dst` through
         * its own branch -- `merge` returns a table, so the struct case needs
         * saying separately. */
        "(assert (= (os/mktime base true) (os/mktime (merge-into @{} base) true)))\n"
        "(assert (not= (os/mktime (struct ;(kvs base) :dst true) true)\n"
        "              (os/mktime (struct ;(kvs base) :dst false) true)))\n"
        "(assert (= (os/mktime (merge base {:dst true}) true)\n"
        "           (os/mktime (struct ;(kvs base) :dst true) true)))\n"
        "(assert (= (os/mktime base) (os/mktime base nil)))\n"
        /* `os/cryptorand`'s second argument appends rather than replacing.
         * The negative-count check happens before the host is asked, so it
         * holds in a build with no entropy source; everything else does not,
         * because `janet_cryptorand` then always fails. */
        "(assert (= \"expected positive integer\" (in (protect (os/cryptorand -1)) 1)))\n"
#ifndef JANET_NO_CRYPTORAND
        "(assert (= 4 (length (os/cryptorand 4))))\n"
        "(def b @\"XY\")\n"
        "(assert (= b (os/cryptorand 4 b)))\n"
        "(assert (= 6 (length b)))\n"
        "(assert (= \"XY\" (string (buffer/slice b 0 2))))\n"
        "(assert (= 0 (length (os/cryptorand 0))))\n"
#else
        "(assert (= \"unable to get sufficient random data\"\n"
        "           (in (protect (os/cryptorand 4)) 1)))\n"
#endif
        /* `os/setlocale`'s category argument, all six of them. */
        "(each cat [:all :collate :ctype :monetary :numeric :time]\n"
        "  (assert (string? (os/setlocale nil cat)) (string \"category \" cat)))\n"
        "(assert (string? (os/setlocale nil)))\n"
        "(assert (string? (os/setlocale nil nil)))\n"
        /* `os/isatty` defaults to stdout and otherwise asks about its
         * argument, which under the contract driver is not a terminal. */
        "(def f (file/temp))\n"
        "(assert (= false (os/isatty f)))\n"
        "(file/close f)\n");
}

#if !defined(JANET_NO_PROCESSES) && !defined(JANET_WINDOWS)

/* `os/spawn`'s redirections and flags. Everything here needs a subprocess
 * that actually produces output or an exit code, which is why none of it is
 * reachable from the type-shape test above. */
static void test_spawn_redirection(void) {
#ifdef JANET_EV
    JanetTable *env = janet_core_env(NULL);
    run(env,
        /* `:pid` exists on POSIX and `:return-code` only after the wait. */
        "(def p (os/spawn [\"/bin/sh\" \"-c\" \"exit 7\"] :p))\n"
        "(assert (int? (p :pid)))\n"
        "(assert (string/has-prefix? \"key :return-code not found\"\n"
        "           (in (protect (p :return-code)) 1)))\n"
        "(assert (= 7 (os/proc-wait p)))\n"
        "(assert (= 7 (p :return-code)))\n"
        /* A pipe on each of the three, and `:err :out` folding one into the
         * other. */
        "(def q (os/spawn [\"/bin/sh\" \"-c\" \"echo o; echo e 1>&2\"] :p\n"
        "                 {:out :pipe :err :pipe}))\n"
        "(def qo (string (:read (q :out) :all)))\n"
        "(def qe (string (:read (q :err) :all)))\n"
        "(os/proc-wait q)\n"
        "(assert (= \"o\\n\" qo))\n"
        "(assert (= \"e\\n\" qe))\n"
        "(def r (os/spawn [\"/bin/sh\" \"-c\" \"echo o; echo e 1>&2\"] :p\n"
        "                 {:out :pipe :err :out}))\n"
        "(def ro (string (:read (r :out) :all)))\n"
        "(os/proc-wait r)\n"
        "(assert (= 2 (length (string/split \"\\n\" (string/trim ro)))))\n"
        /* Writing into the child through `:in`. */
        "(def t (os/spawn [\"/bin/cat\"] :p {:in :pipe :out :pipe}))\n"
        "(:write (t :in) \"zz\") (:close (t :in))\n"
        "(def to (string (:read (t :out) :all)))\n"
        "(os/proc-wait t)\n"
        "(assert (= \"zz\" to))\n");
    janet_deinit();

    janet_init();
    env = janet_core_env(NULL);
    run(env,
        /* A core/file rather than a pipe, which is the branch of
         * `get_stdio_for_handle` that duplicates the descriptor. */
        "(def f (file/temp))\n"
        "(def p (os/spawn [\"/bin/echo\" \"ff\"] :p {:out f}))\n"
        "(os/proc-wait p)\n"
        "(file/seek f :set 0)\n"
        "(assert (= \"ff\\n\" (string (file/read f :all))))\n"
        "(file/close f)\n"
        /* `os/proc-close` closes the pipes it owns and then waits; called
         * again after a wait it returns nil rather than waiting twice. */
        "(def q (os/spawn [\"/bin/echo\" \"x\"] :p {:out :pipe}))\n"
        "(assert (number? (os/proc-close q)))\n"
        "(def r (os/spawn [\"/usr/bin/true\"] :p))\n"
        "(assert (= 0 (os/proc-wait r)))\n"
        "(assert (= nil (os/proc-close r)))\n"
        /* The `:x` flag turns a non-zero exit into a raised error, and only
         * for a waiting fiber. */
        "(def s (os/spawn [\"/bin/sh\" \"-c\" \"exit 3\"] :px))\n"
        "(assert (= \"command failed with non-zero exit code 3\"\n"
        "           (in (protect (os/proc-wait s)) 1)))\n"
        "(def u (os/spawn [\"/bin/sh\" \"-c\" \"exit 3\"] :p))\n"
        "(assert (= 3 (os/proc-wait u)))\n");
#endif
}

/* The environment block `os/execute` builds under `:e`. Its POSIX arm drops a
 * key holding `=` or NUL and keeps everything else, which is a rule
 * `-Dos-process` owns and this is the only thing that runs it end to end. */
static void test_execute_environment(void) {
    JanetTable *env = janet_core_env(NULL);
    run(env,
        /* With `:e` the child sees exactly what was passed. */
        "(assert (= 0 (os/execute [\"/bin/sh\" \"-c\" \"test \\\"$JP\\\" = v\"] :pe\n"
        "                         {\"JP\" \"v\"})))\n"
        /* And nothing else: the parent's environment is not inherited. */
        "(os/setenv \"JP_PARENT\" \"set\")\n"
        "(assert (= 0 (os/execute [\"/bin/sh\" \"-c\" \"test -z \\\"$JP_PARENT\\\"\"] :pe\n"
        "                         {\"JP\" \"v\"})))\n"
        /* Without `:e` it is. */
        "(assert (= 0 (os/execute [\"/bin/sh\" \"-c\" \"test \\\"$JP_PARENT\\\" = set\"] :p)))\n"
        "(os/setenv \"JP_PARENT\")\n"
        /* A key holding `=` is dropped rather than passed. */
        "(assert (= 0 (os/execute [\"/bin/sh\" \"-c\" \"test -z \\\"$JP\\\"\"] :pe\n"
        "                         {\"J=P\" \"v\"})))\n"
        /* A non-string key or value is skipped, and an empty block is legal. */
        "(assert (= 0 (os/execute [\"/bin/sh\" \"-c\" \"true\"] :pe {:kw \"v\" \"k\" 5})))\n"
        "(assert (= 0 (os/execute [\"/bin/sh\" \"-c\" \"true\"] :pe {})))\n"
        /* `:p` decides whether PATH is searched. */
        "(assert (not (first (protect (os/execute [\"sh\" \"-c\" \"true\"])))))\n"
        "(assert (= 0 (os/execute [\"sh\" \"-c\" \"true\"] :p)))\n");
}

/* `os/sigaction` installs, replaces and removes a handler, and the third
 * argument selects the interrupting trampoline. None of that is observable
 * from a return value, so what is asserted is that each shape is accepted and
 * that the signal table is consulted first. */
static void test_sigaction(void) {
#ifdef JANET_EV
    JanetTable *env = janet_core_env(NULL);
    run(env,
        "(os/sigaction :usr1 (fn [] nil))\n"
        "(os/sigaction :usr1 (fn [] nil))\n"
        "(os/sigaction :usr1)\n"
        "(os/sigaction :usr1 nil)\n"
        "(os/sigaction :usr2 (fn [] nil) true)\n"
        "(os/sigaction :usr2 (fn [] nil) false)\n"
        "(os/sigaction :usr2)\n"
        /* The keyword is looked up before anything is installed. */
        "(assert (= \"undefined signal :nosuchsignal\"\n"
        "           (in (protect (os/sigaction :nosuchsignal (fn [] nil))) 1)))\n");
#endif
}

/* `os/posix-fork` returns nil in the child and a `core/process` in the parent.
 * The child exits with `force` so that it does not flush the buffered output
 * the parent has already queued -- which is what makes this safe to run inside
 * a contract at all. */
static void test_posix_fork(void) {
    JanetTable *env = janet_core_env(NULL);
    run(env,
        "(def p (os/posix-fork))\n"
        "(if p\n"
        "  (do (assert (= :core/process (type p)))\n"
        "      (assert (int? (p :pid)))\n"
        "      (assert (= 0 (os/proc-wait p))))\n"
        "  (os/exit 0 true))\n");
}

#endif /* !JANET_NO_PROCESSES && !JANET_WINDOWS */

/* `os/exit`'s `force` argument is *not* tested here, and the reason is worth
 * recording because the mutation sweep asks about it twice.
 *
 * `force` chooses `_Exit` over `exit`, and the only visible difference is
 * whether the C library's buffered output is flushed on the way out. That can
 * only be asked of a child process running a Janet snippet, and this contract
 * has no interpreter to spawn: `(dyn :executable)` is the CLI's binding and
 * `janet_core_env` does not set it, so a contract linked against the library
 * cannot name a janet binary. Forking in C and redirecting the child through
 * a pipe would work and is more machinery than two mutants are worth.
 *
 * Both mutants therefore stand as deliberate survivors. The behaviour itself
 * is real and was verified by hand: `(prin "x") (os/exit 0)` prints `x` and
 * `(prin "x") (os/exit 0 true)` prints nothing. */

/* `os/pipe` and its two flag letters. */
static void test_pipe(void) {
#ifdef JANET_EV
    JanetTable *env = janet_core_env(NULL);
    run(env,
        "(def [r w] (os/pipe))\n"
        "(:write w \"abc\")\n"
        "(assert (= \"abc\" (string (:read r 3))))\n"
        "(:close w) (:close r)\n"
        /* nil is not a flag set, and is accepted where a keyword would be. */
        "(def [r2 w2] (os/pipe nil))\n"
        "(:close w2) (:close r2)\n"
        /* `:W` makes the writable end blocking, which the stream reports by
         * refusing an ev write; `:R` does the same to the readable end. */
        "(def [r3 w3] (os/pipe :W))\n"
        "(assert (= \"bad stream, expected writable stream\"\n"
        "           (in (protect (:write w3 \"x\")) 1)))\n"
        "(:close w3) (:close r3)\n"
        "(def [r4 w4] (os/pipe :R))\n"
        "(assert (= \"bad stream, expected readable stream\"\n"
        "           (in (protect (:read r4 1)) 1)))\n"
        "(:close w4) (:close r4)\n");
#endif
}

void os_surface_contract(void) {
    janet_init();
    test_stat_read();
    janet_deinit();

    janet_init();
    test_registration();
    janet_deinit();

    janet_init();
    test_calendar();
    janet_deinit();

    janet_init();
    test_permissions();
    janet_deinit();

    janet_init();
    test_clock();
    janet_deinit();

    janet_init();
    test_environment();
    janet_deinit();

    janet_init();
    test_platform();
    janet_deinit();

    janet_init();
    test_optional_arguments();
    janet_deinit();

    janet_init();
    test_open_flags();
    janet_deinit();

    janet_init();
    test_rm_sandbox();
    janet_deinit();

    janet_init();
    test_links();
    janet_deinit();

    janet_init();
    test_pipe();
    janet_deinit();

#if !defined(JANET_NO_PROCESSES) && !defined(JANET_WINDOWS)
    janet_init();
    test_proc_type();
    janet_deinit();

    janet_init();
    test_signal_table();
    janet_deinit();

    janet_init();
    test_spawn_redirection();
    janet_deinit();

    janet_init();
    test_execute_environment();
    janet_deinit();

    janet_init();
    test_sigaction();
    janet_deinit();

    janet_init();
    test_posix_fork();
    janet_deinit();

#endif
}

#else /* JANET_REDUCED_OS */

/* A reduced-OS build compiles four `os/` functions and none of this file's
 * subjects. `src/zig/README.md` records that the Janet suites cannot run
 * against such a build at all; the library still has to link, which is what
 * that matrix entry claims and all this stub is for. */
void os_surface_contract(void) {
}

#endif /* JANET_REDUCED_OS */
