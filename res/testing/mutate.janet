#!/usr/bin/env janet
# Mutation sweep over the Zig sources.
#
# Development instrument in `res/`. The judge is the same for every source,
# so there is no per-increment edit.
#
#     ./res/testing/mutate.janet --src src/runtime/ev.zig
#     ./res/testing/mutate.janet --src src/runtime/ev.zig --only 3,17,64
#     ./res/testing/mutate.janet --src A --only 3,17 --src B --only 5 --no-strings
#     unsetopt BG_NICE; nohup ./res/testing/mutate.janet --src A --src B \
#       --no-strings --log /tmp/2a.log &
#     ./res/testing/mutate.janet --src A --src B --log /tmp/2a.log --resume /tmp/2a.log
#     ./res/testing/mutate.janet --all --log /tmp/wattle-mutate.log
#     ./res/testing/mutate.janet --src src/runtime/ev.zig --stage full
#
# One of `--src` and `--all` is required; a bare invocation prints this usage
# and stops, because a whole-tree run is thirty hours and is not something to
# start by typing the program's name.
#
# `--src` is repeatable and sweeps the sources in the order given, under one
# warm-up, one log and one set of totals. That is the batch, which is how Part
# 2 runs the sweep: twelve runs of two or three hours, each read the same day.
#
# A batch is launched in the background, and under zsh that needs
# `unsetopt BG_NICE` first: the option is on by default and runs every `&` job
# at nice +5, which a host with other work on it starves. Phase 20's 2a and 2b
# ran niced without noticing, and runs bounded at twelve seconds were measured
# at 325. `ps -o pid,ni,stat -p <pid>` after launching should read `NI 0` with
# no `N` in the state. `mutation.md` has the measurement.
#
# ## It holds idle sleep off for itself
#
# A sweep is unattended by definition, so the host is idle by every measure the
# power manager takes and it sleeps underneath the run. A frozen process
# resumes where it stopped, so each nap lands inside whatever step was in
# flight and that step's wall clock spans it: batch 2f took 61 naps in four
# hours and read `contracts=238.9` against a bound of twelve. The verdicts were
# right, because the retry re-runs a step that times out and the second attempt
# lands on a machine that is awake, but a bound that holds only because a retry
# rescues it is not a bound.
#
# `caffeinate -i` does not fix it, which is worth writing down because it is
# the obvious answer: it asserts against *idle* sleep, and with the display off
# and no input this host sleeps anyway. What works is the setting, and the
# operator's session hooks already drive it -- `sudo -n /usr/bin/pmset -a sleep
# 0` while a session is working and `-a sleep 1` when the last one goes idle,
# reference counted through one marker file per session under
# `$HOME/.claude/run/busy` because a global setting has no refcount of its own.
# A detached sweep is not a session turn, so when every session goes idle that
# directory empties and sleep comes back on underneath it. That is the whole of
# the cause.
#
# So the warm-up puts a marker of its own in that directory and disables sleep,
# and the restore on the way out removes it and re-enables sleep only if the
# directory is then empty, which is the same refcount the hooks use and leaves
# a working session's marker alone. Every failure is swallowed and announced:
# a power setting must never stop a sweep, and an operator who is told the
# marker could not be placed knows the run will be slept through.
#
# A sweep killed with `SIGKILL` does not reach the restore. It leaves the
# marker in place and sleep switched off until the marker is removed by hand,
# along with the `git status` an interrupted sweep already owes. An abort does
# not reach the restore either, because `tools/die` exits and an exit does not
# run a `defer`, so every abort after the marker is placed goes through
# `abort`, which releases the marker first. The warm-up's aborts come before
# the marker is placed and have nothing to release.
#
# Several runs chained under one `nohup` leave the gaps between them
# unprotected: each run's exit restores sleep, an idle host sleeps at once, and
# the next run's warm-up comes before its marker. So a round of re-runs over
# several sources is one run, with an `--only` after each `--src`.
#
# `--all` sweeps every source under `src/` with at least one site and implies
# `--no-strings`; `--strings` puts the string-literal sites back. `--only`
# names sites in the `--src` before it, and a `--src` with no `--only` after
# it sweeps every site.
#
# ## The judge escalates, because most mutants die cheaply
#
# A default `zig build` does not reach every half of every subsystem.
# `janet_native`'s success path is reached only by `test/zig-native.janet`,
# which `build.zig` hangs off the *test* step: `test_step.dependOn` at the run
# artifact, not the install step. So a mutant is put through as little as will
# kill it:
#
#     default   zig build, then startup, every contract, and every suite
#     full      zig build test, the whole graph
#
# A build that exceeds its bound is built a second time before it is scored
# `build (hang)`, because on this host a build that follows a runaway image
# generator can be starved past the bound without being slow itself. Every
# other bounded step -- the smoke run, the contract run, each suite and the
# full stage -- is run a second time on a timeout for the same reason, and
# scores a hang only if the second attempt times out as well.
#
# A mutant that survives both is a survivor. `--stage` pins the judge to one of
# them when you already know which is the interesting one.
#
# **There was a third stage and it is gone, along with its reason.** `boot` built
# `-Dboot=zig` and re-ran startup and the suites, because `janet_core_env` has a
# bootstrap implementation that only the image generator compiles and the
# generator was C by default -- so a mutation to the Zig bootstrap half was not
# compiled by `default` at all. Phase 10 Part 17g removed `-Dboot` by removing
# the C generator: every `zig build` now builds `wattle-boot` from the same Zig
# sources, because that is the only thing that can emit an image. `default`
# therefore compiles what `boot` was added to reach, and Phase 11 Part 10's
# lesson 26 is the evidence -- two mutations to `value_wrap.zig` broke the
# *bootstrap*, under a plain `zig build`, and the build failed at `run exe
# wattle-boot`.
#
# ## Two disciplines this bakes in, both learned the hard way
#
# **It checks, after every mutant, that the source still holds the mutation it
# was judging.** `AGENTS.md` says never to edit the file a sweep is mutating, and
# the way that rule actually gets broken is not a deliberate edit -- it is a bulk
# `sed` or a global rename whose *file list* happens to include the source. If
# such an edit lands while a build is in flight, the mutation is lost and
# unmutated source is scored as a survivor; if it lands between mutants, the
# harness's restore silently discards it. Both are invisible in the log.
#
# The check has to come *after* the verdict, not after the write. A build plus a
# suite run is half a minute; the instant after the write is microseconds, and an
# interfering edit almost certainly lands in the former. Comparing the file to
# what was written, once the verdict is in, is what makes the verdict trustworthy
# -- and a sweep that cannot be trusted is worse than no sweep.
#
# The Python original compared SHA-256 digests. Janet has no hash in its core,
# and none is needed: the mutated text is already in hand, so the check compares
# the bytes themselves. That is exact where a digest was merely very probably
# exact, and it removes a dependency rather than replacing one.
#
# **It gets a cache of its own and prunes it after every mutant.** Every mutant is
# a distinct source *content*, and `.zig-cache` is never garbage collected, so a
# sweep deposits a fresh object set per mutant. Left alone it reached 116GB and
# filled a 460GB disk partway through Part 10's first attempt -- after which
# builds fail for reasons that have nothing to do with the mutation, and those
# failures are recorded as verdicts too.
#
# Periodic wiping bounds that but wastes a cold rebuild each time. Measured on
# this project, a mutant adds about 400MB in **five** cache entries and reuses the
# other three hundred, so deleting exactly those five after each mutant holds the
# cache flat at one build's worth -- 1.28GB steady, 1.68GB peak -- and costs
# nothing, because the shared objects survive and each rebuild is three seconds
# rather than a minute.
#
# The five are found by set difference against a **baseline built from unmutated
# source before the sweep starts**, one warm-up build per stage the run can
# reach. Two other discriminators were tried and are wrong. Age fails because Zig
# stamps entries on cache *hits* as well as on creation, so mtime pruning deletes
# the shared objects too. Delta *size* fails because a `zig build test` run
# relinked forty-odd contract executables against the mutated library, so a
# per-mutant delta there is large -- treating large deltas as shared
# infrastructure let the cache grow 4.5GB per mutant, 1.8GB to 28GB over six.
# That is one executable now, which shrinks the delta and leaves the conclusion
# alone: size still cannot separate the two.
#
# The baseline is exact instead of heuristic: an unmutated build produces
# precisely the entries whose inputs the mutation does not touch, so everything
# outside it is this mutant's own and everything inside it is worth keeping.
#
# The warm-up earns its cost twice over, because a stage that fails here means
# the tree is not green, and **a sweep against a failing baseline measures
# nothing.** It is much better to find that out in the first minute than to read
# a log of two hundred meaningless verdicts.
#
# **And it stops before the disk does, in two ways.** An ENOSPC in the middle of a
# build looks exactly like a mutant that failed to compile, and `judge-default`
# would score it as one, so neither guard is optional.
#
# The first is a floor: if free space falls under `min-free-gb` the sweep prunes,
# and if that is not enough it aborts. That guard *predicts*, and on macOS it
# predicts badly -- `statvfs` reports what is free now and knows nothing about
# purgeable space, which the OS returns the moment a writer needs it. Phase 10
# Part 13 measured 28.2GB by `statvfs` against 143.3GB the system would actually
# give, and lost two sweeps to the gap before the floor was lowered.
#
# The second is exact and portable, and is the one to rely on: every judged build
# goes through `refuse-if-disk-full`, which looks for the volume-full message in
# the output and aborts rather than returning a verdict. Detecting the failure
# where it happens beats guessing at it beforehand.
#
# ## Reading the output
#
# Each line is one mutant: its index, the verdict, the line and kind of the
# mutation, and -- when it was caught -- *what* caught it. The attribution is the
# point. A subsystem the runtime bootstraps through gets many free catches from
# startup alone, and a sweep that only asks "did something fail" reports those as
# though a test performed them. The tally at the end separates them, and the
# survivor list is printed in a form you can paste straight back into `--only`.
#
# **A site index is a position in an enumeration, and `--no-strings` changes
# that enumeration**, so the printed re-run line carries the flag the run used
# and the log's last field names it. Pasting a line that has lost the flag
# mutates different sites in every source that holds a string-literal site,
# with no diagnostic; Phase 20 Part 3e lost twenty-one verdicts that way.
#
# `uncompilable` means the compiler refused the mutation and nothing else: a
# build that failed because the image generator refused instead scores
# `bootstrap: <reason>`, because the generator is a test layer and a mutant it
# killed is a mutant a test caught.
#
# ## A mutant that changes no code is not a survivor
#
# After the default stage's build the judge digests each content-bearing
# section of each Mach-O file the build installed and compares the digests with
# the ones unmutated source produced at warm-up. A mutation in an arm this
# configuration does not compile leaves all of them identical, and such a
# mutant scores `no effect` in a tally row of its own rather than as a
# survivor. Nothing is run for it and no later stage is reached.
#
# The comparison is made once, at that build, and is final. `zig build test`
# installs nothing: measured 2026-09-08, it left all twelve installed files
# identical by mtime and digest, and installed zero files when it ran into an
# empty prefix. Every build passes `-Dinstall-tests=true`, so the prefix that
# one comparison reads already holds the runtime test executable and the four
# example modules, which is everything the full stage would have compiled.
# There is nothing a second comparison could find.
#
# Comparing the file instead does not work. The executables carry two `OSO`
# stabs naming object files in the cache directory, so `__LINKEDIT` holds a
# path whose length moves with the mutation and every mutant differs. The two
# zero-fill sections have no file contents and are skipped.

(import ../common :as tools)

### discipline

(def cache "/tmp/wattle-mutate-cache")
(def prefix "/tmp/wattle-mutate-out")

# Files the Janet suites create in the working tree and delete again when they
# pass. A mutant that makes one of them *fail* leaves the file behind, and the
# next mutant then fails the same suite for a reason that has nothing to do
# with it -- every verdict after the first casualty is "caught" by debris.
#
# Phase 10 Part 12 lost a whole phase to this and it was invisible in the log:
# a mutated `os/open` mode created `unique.txt` with permissions 0000, so
# `test/suite-ev.janet` could not reopen it, and fifty-seven of seventy-four
# mutants were recorded as caught by `suite-ev.janet (fail)`. The attribution
# column is what gave it away -- a file-writing suite has no business catching
# mutations in a permission parser -- which is Part 8's rule about labelling
# the catcher paying for itself a second time.
#
# Cleaned before every judged run rather than after, so that debris from
# anything else is cleared too.
# Re-derived by grepping every suite for the paths it creates, because every
# suite now runs for every mutant rather than three of them. `tmp_dir_*` is
# `helper.janet`'s `randdir`, which `suite-bundle` and `suite-filewatch` build
# their trees under, so the `file1.txt` kind of leaf goes with its directory.
# `wattle-suite-*` covers `suite-io`, `suite-filewatch` and `suite-net`. `tmp`
# is a directory `suite-ev2` makes and fills.
(def debris
  ["unique.txt"
   "unix-domain-socket"
   "tempdir123"
   "tmp"
   "tmp_dir_*"
   "wattle-suite-*"])

# Seconds for the default stage's build. A plain `zig build` runs the image
# generator and nothing else that can loop: the warm-up build is 14 seconds and
# a cold one about a minute, so three minutes is a wide margin and ten was a
# tenth of an hour spent on each mutant that hangs the bootstrap. Phase 20
# batch 2b had three of those.
#
# **A build that exceeds it is built a second time before it is called a hang.**
# The bound measures the mutant only when the machine is quiet, and on this host
# it is not: a mutation that makes the image generator loop grows it without
# bound -- `parser.zig` 283 reached 5.8GB of a 24GB machine in the 174 seconds
# it was allowed -- and the mutants that follow one of those build slowly for
# reasons of their own. Batch 2c scored thirty `build (hang)`; four were re-run
# afterwards and three of them, `scan.zig` 28, 97 and 197, build in 8.8 seconds
# and are caught by a contract in eleven. They were not hangs and the column
# said they were. The second attempt costs `build-bound` seconds again for a
# real hang, which is rare, and turns a starvation into the verdict the mutant
# earned. Both attempts' seconds are kept, as `build=180.0+8.8`, so a record
# can still count the starvations.
(def build-bound 180)

# Seconds per judged run that is not a build; a hang counts as caught. The
# contract call had its own 600 and no longer does: all sixty-five contracts
# run in one process in under three seconds, so a mutant that hangs one cost
# fifty times a mutant that hung a suite, and `ev/backend.zig` is the event
# loop. A build keeps its own longer bound, because a build that is slow is not
# a hang the mutant caused.
#
# **A step that exceeds it is run a second time before it is called a hang.**
# Twelve seconds bounds a suite that passes in a fifth of one, so the margin is
# wide until the host is busy, and on this host it is: another session's load
# starves a passing step past the bound and the mutant is scored for it. Phase
# 20 Part 3e scored three mutants caught by a hang in a suite with no
# connection to the subject, and all three came back `SURVIVED` when they were
# run again. What is lost is more than the verdict. The catcher is the first
# suite that failed in directory order, so a starved early suite stands in
# front of the suite that would have caught the mutant, and the attribution
# column reports the wrong one -- which is what Part 3e found at `peg.zig` 127,
# where `suite-ev` hung and `suite-peg` held the assertion. The second attempt
# costs `bound` seconds again for a real hang, and both attempts' seconds are
# kept, as `contracts=12.0+12.0`, so a record can count the starvations.
(def bound 12)
# Gigabytes free below which the sweep prunes, then aborts. The floor is a
# coarse backstop. On macOS `statvfs` reads free space before the OS purges its
# purgeable caches, so it can read low on a volume with plenty to give, and a
# higher floor stops a healthy run. The guard is `refuse-if-disk-full`, which
# reads the build's own volume-full message and aborts rather than score it.
#
# It decides whether the run continues and not any mutant's verdict, so it is
# safe to change between runs.
(def min-free-gb 3)

### mutations

# Janet's `:w` is alphanumeric and does not include the underscore, so Python's
# `\w` -- and therefore `\b` -- is spelled out.
(def- word ~(choice :w "_"))
(def- boundary ~(not ,word))
(def- after-boundary ~(not (look -1 ,word)))

# Each entry is [pattern replacement name]. The order matters only in that
# `==` is tried before `!=`, so a line holding both yields two distinct sites
# rather than one applied twice.
(def mutations
  [[~(sequence (not (look -1 (set "<>=!+-*/"))) "<" (not (set "<="))) "<=" "lt->le"]
   [~(sequence (not (look -1 (set "<>=!+-*/"))) ">" (not (set ">="))) ">=" "gt->ge"]
   [~"<=" "<" "le->lt"]
   [~">=" ">" "ge->gt"]
   [~"==" "!=" "eq->ne"]
   [~"!=" "==" "ne->eq"]
   [~(sequence ,after-boundary "and" ,boundary) "or" "and->or"]
   [~(sequence ,after-boundary "or" ,boundary) "and" "or->and"]
   [~(sequence "+= 1" ,boundary) "+= 2" "step"]
   [~(sequence "-= 1" ,boundary) "-= 2" "step"]
   [~(sequence "+ 1" ,boundary) "+ 2" "off-by-one"]
   [~(sequence "- 1" ,boundary) "- 2" "off-by-one"]
   [~(sequence ,after-boundary "true" ,boundary) "false" "true->false"]
   [~(sequence ,after-boundary "false" ,boundary) "true" "false->true"]])

# One compiled scanner per mutation, capturing the start and end of every
# non-overlapping occurrence -- which is what `re.finditer` gives.
(def- scanners
  (map (fn [[patt _ _]]
         (peg/compile ~(any (choice (sequence (position) ,patt (position)) 1))))
       mutations))

# A string literal, for blanking: `"(?:[^"\\]|\\.)*"`.
(def- string-literal
  (peg/compile
    ~(any (choice
            (sequence (position)
                      "\"" (any (choice (sequence "\\" 1) (if-not (set "\"\\") 1))) "\""
                      (position))
            1))))

(defn- blank-strings
  "Replace every string literal with spaces of the same length."
  [line]
  (def spans (peg/match string-literal line))
  (if (empty? spans)
    line
    (let [out (buffer line)]
      (var i 0)
      (while (< i (length spans))
        (for k (spans i) (spans (+ i 1)) (put out k (chr " ")))
        (+= i 2))
      (string out))))

(defn sites
  "One mutation per (line, kind, occurrence).

  Doc comments and lines that are nothing but a continued string literal are
  skipped: mutating a docstring tests the tests. Words *inside* a message
  literal on a code line are a different matter and are included by default --
  Part 10 found three of them surviving every pass, which is how it noticed
  that `assert-error` compares nothing but the fact of an error. Pass
  `--no-strings` to leave them alone, along with every line of a Zig
  multiline string, which begins `\\\\` and which blanking cannot reach."
  [lines in-strings]
  (def out @[])
  (for i 0 (length lines)
    (def line (lines i))
    (def stripped (string/trim line))
    (unless (or (string/has-prefix? "//" stripped)
                (string/has-prefix? "\"" stripped)
                (string/has-prefix? "++" stripped)
                (and (not in-strings) (string/has-prefix? "\\\\" stripped)))
      (def body (if in-strings line (blank-strings line)))
      (for m 0 (length mutations)
        (def [_ repl kind] (mutations m))
        (def spans (peg/match (scanners m) body))
        (var s 0)
        (while (< s (length spans))
          (array/push out [i (spans s) (spans (+ s 1)) repl kind])
          (+= s 2)))))
  out)

(defn apply-mutation [lines site]
  (def [i a b repl _] site)
  (def copy (array/slice lines))
  (put copy i (string (string/slice (copy i) 0 a) repl (string/slice (copy i) b)))
  (string/join copy "\n"))

(defn- cache-entries []
  (def out @{})
  (each entry (try (os/dir (string cache "/o")) ([_] []))
    (put out entry true))
  out)

(defn- prune
  "Delete everything this mutant added on top of the baseline."
  [keep]
  (eachk entry (cache-entries)
    (unless (keep entry)
      (tools/rm-rf (string cache "/o/" entry)))))

(defn- cache-gb []
  (/ (tools/dir-bytes cache) (* 1024 1024 1024)))

### sections

# Every build passes this, so the runtime test executable and the four example
# modules are installed under `<prefix>/test` and are compared with the rest. A
# mutation in `src/module.zig` lands in the example modules and in nothing else
# the default build installs. It is what makes one comparison enough: without
# it the prefix would hold none of what the test step runs, and `zig build
# test` installs nothing of its own to make up the difference.
(def- build-flags "-Dinstall-tests=true")

# 64-bit Mach-O, little-endian, which is what this host links. The check also
# excludes `libwattle.a`: an archive begins `!<arch>` and carries the DWARF the
# executables leave behind, so comparing it would report a difference for every
# mutant and defeat the comparison it is part of.
(def- macho-magic "\xcf\xfa\xed\xfe")

(defn- macho? [path]
  (= macho-magic
     (try (with [f (file/open path :rb)] (string (or (file/read f 4) "")))
       ([_] nil))))

(defn- prefix-files
  "Every Mach-O file the build installed, in a fixed order."
  []
  (def out @[])
  (each dir ["bin" "lib" "test"]
    (each entry (sort (try (os/dir (string prefix "/" dir)) ([_] [])))
      (def path (string prefix "/" dir "/" entry))
      (when (and (= :file (try (os/lstat path :mode) ([_] nil))) (macho? path))
        (array/push out path))))
  out)

(defn- zero-fill?
  "Whether a section's flags name a type that has no file contents.

  The type is the flags' low byte: `S_ZEROFILL` 01, `S_GB_ZEROFILL` 0c and
  `S_THREAD_LOCAL_ZEROFILL` 12. It is read from the last two characters rather
  than with `band`, because `otool` prints flags with the high bit set and
  Janet's `band` takes a 32-bit signed integer."
  [flags]
  (def hex (string/ascii-lower flags))
  (def low (if (>= (length hex) 2) (string/slice hex -3) hex))
  (truthy? (find |(= $ low) ["01" "0c" "12"])))

(defn- section-list
  "Every content-bearing section of every Mach-O under the prefix.

  One `otool -l` for the whole set, with a marker line before each file,
  because the listing is nine milliseconds and the parse is the same either
  way."
  [files]
  (if (empty? files)
    @[]
    (do
      (def r (tools/sh (string/join
                         (map |(string "echo '@@ " $ "'; otool -l " $) files) "; ")
                       :timeout 120))
      (def out @[])
      (var path nil)
      (var in-section false)
      (var seg nil) (var sect nil) (var flags nil)
      (defn close []
        (when (and in-section path seg sect flags (not (zero-fill? flags)))
          (array/push out [path seg sect]))
        (set in-section false) (set seg nil) (set sect nil) (set flags nil))
      (each line (string/split "\n" (tools/both r))
        (def words (filter |(not (empty? $)) (string/split " " (string/trim line))))
        (unless (empty? words)
          (cond
            (= (words 0) "@@") (do (close) (set path (get words 1)))
            (= (words 0) "Section") (do (close) (set in-section true))
            (= (words 0) "Load") (close)
            (and in-section (= (words 0) "sectname")) (set sect (get words 1))
            (and in-section (= (words 0) "segname")) (set seg (get words 1))
            (and in-section (= (words 0) "flags")) (set flags (get words 1)))))
      (close)
      out)))

# A Linux sweep would list sections here, with `readelf -S` for the list and
# `readelf -x` for the bytes. The sweep runs on this machine and a second
# lister is not owed until one runs elsewhere.

# Where the parallel digest jobs put their lines. Each writes its own file and
# one `cat` after the `wait` puts them on the shell's stdout, so no background
# job holds the pipe `tools/sh` is reading to `:all`. A job that inherits that
# pipe and outlives the `wait` keeps it open, the read never finishes, and the
# whole digest costs its bound; `mutation.md` records the same hazard for a
# contract that lets a child inherit its stdio, and this shell had it too.
(def- scratch "/tmp/wattle-mutate-digest")

# The digest is 0.44 seconds over 139 sections, so this is a backstop rather
# than a budget. It was 300, which is what a single stall cost the 2a batch,
# twenty times.
(def- digest-bound 60)

# Set when the digest shell hits its bound, cleared per mutant by `judge`. The
# main loop reads it, warns with the mutant's name, and records it on the log
# line, because a stalled digest is not evidence of anything.
(var- digest-timeout false)

# What each step of the current mutant's judging cost, in the order the steps
# ran. `judge` clears it. A batch that runs slower than it was priced is located
# from this rather than guessed at.
(var- steps @[])

(defn- timed
  "Run `thunk`, record what it cost under `name`, and answer its result."
  [name thunk]
  (def began (os/clock))
  (def out (thunk))
  (array/push steps [name (- (os/clock) began)])
  out)

(defn- step-costs
  "What each step of this mutant cost, as `name=seconds`, in the order they ran.

  The suites fold into one figure. There are thirty-four of them and naming
  each would be most of the log line; the one that caught the mutant is already
  the catcher field, and a suite run that stopped early is what the total
  should show. A suite the judge ran twice is the retry at `bound`, and its
  second attempt folds into a figure of its own so that `suites=12.0+3.1`
  reads the way `build=180.0+8.8` does."
  []
  (def out @[])
  (var suites 0)
  (var retried 0)
  (var suites-at nil)
  (var last-name nil)
  (var last-at nil)
  (each [what took] steps
    (if (string/has-prefix? "suite:" what)
      (do (if (= what last-name) (+= retried took) (+= suites took))
          (when (nil? suites-at) (set suites-at (length out)) (array/push out nil))
          (set last-name what))
      # A step the judge ran twice is a retry, and reading the two attempts
      # apart is the point of keeping them: `build=180.0+8.8` is a starved
      # first attempt and `build=180.0+180.0` is a real hang. Summing them
      # would lose that and replacing them would lose the starvation.
      (if (= what last-name)
        (put out last-at (string (out last-at) (string/format "+%.1f" took)))
        (do (set last-at (length out))
            (set last-name what)
            (array/push out (string/format "%s=%.1f" what took))))))
  (when suites-at
    (put out suites-at
         (if (zero? retried)
           (string/format "suites=%.1f" suites)
           (string/format "suites=%.1f+%.1f" suites retried))))
  (string/join out ","))

(defn- digests
  "A digest of every content-bearing section of every Mach-O under the prefix.

  Sixteen jobs at a time, because `otool` is the whole cost: 139 sections over
  eleven files take 1.8 seconds one after another and 0.44 in parallel. Each
  job writes its line with one `echo`, which is one write well under `PIPE_BUF`,
  so the lines interleave with each other but are never split, and the result is
  sorted. Answers nil when the section list is empty or a line went missing, and
  the caller reads that as a difference."
  []
  (def secs (section-list (prefix-files)))
  (if (empty? secs)
    nil
    (do
      (def parts @[(string "rm -rf " scratch "; mkdir -p " scratch)])
      (for i 0 (length secs)
        (def [path seg sect] (secs i))
        (array/push parts
                    (string "echo \"" path " " seg " " sect " $(otool -X -s "
                            seg " " sect " " path
                            " | shasum -a 256 | cut -d' ' -f1)\" > "
                            scratch "/" i " &"))
        (when (= 15 (% i 16)) (array/push parts "wait")))
      (array/push parts "wait")
      (array/push parts (string "cat " scratch "/*; rm -rf " scratch))
      (def r (tools/sh (string/join parts "\n") :timeout digest-bound))
      # A digest that timed out has no standing. Answering the lines that did
      # arrive would compare a partial build against a whole baseline, and the
      # one verdict that must never come out of a stall is `no effect`.
      (if (r :timeout)
        (do (set digest-timeout true) nil)
        (let [lines (sort (filter |(not (empty? $))
                                  (map string/trim (string/split "\n" (r :out)))))]
          (if (= (length lines) (length secs)) lines nil))))))

# What the unmutated source installed, filled in by the warm-up. One set rather
# than one per stage, because `zig build test` installs nothing: measured
# 2026-09-08, all twelve files identical by mtime and digest after it, and zero
# files installed when it runs into an empty prefix. The prefix is the default
# build's product at every stage.
(var- baseline nil)

(defn- unchanged?
  "Whether this build's sections are the ones unmutated source installed."
  []
  (and baseline (deep= baseline (digests))))

# A build that fails for want of disk is indistinguishable from a mutant that
# failed to compile, and `judge-default` scores any non-zero build as
# "uncompilable" -- so without this the sweep records disk exhaustion as a
# result. The `min-free-gb` floor above was the first attempt at preventing
# that, and it guesses: it reads `statvfs`, which on macOS understates what is
# actually available by whatever the OS is holding as purgeable. Phase 10 Part
# 13 measured 28.2GB by that reckoning against 143.3GB the system would give a
# writer on demand, and lost two sweeps to the difference.
#
# Detecting the failure is exact where predicting it is not, and it is portable.
# The floor stays as a coarse backstop; this is the real guard.
(def- disk-full-phrases
  ["no space left on device" "not enough space" "disk full" "enospc" "unable to write"])

(defn- disk-full? [text]
  (def lower (string/ascii-lower text))
  (or (some |(string/find $ lower) disk-full-phrases)
      # `failed to write.*space`, which the phrase list cannot express.
      (when-let [at (string/find "failed to write" lower)]
        (truthy? (string/find "space" lower at)))))

(defn- brief
  "A catcher's reason, on one line and short enough to sit in a tally row."
  [line]
  (def t (string/trim line))
  (if (> (length t) 70) (string/slice t 0 70) t))

(defn- refuse-if-disk-full [r what]
  (when (and r (not (r :timeout)) (not= 0 (r :code)) (disk-full? (tools/both r)))
    (error {:out-of-space (string/format "%s reported the volume full:\n%s"
                                         what (tools/tail (string/trim (tools/both r)) 400))}))
  r)

# The image generator is a test layer, and a build that fails because it
# refused is not a build the compiler refused. `zig` prints the two
# differently, and this reads that difference rather than the exit status,
# which is 1 either way:
#
#     +- run exe wattle-boot (wattle-image.bin) failure        <- the generator
#     +- compile exe wattle-boot Debug native-native 19 errors <- the compiler
#
# A step that ran something and failed carries a bare ` failure`; a step that
# failed because something under it did carries ` transitive failure`, which
# both kinds print and which therefore decides nothing. Measured on three real
# builds rather than assumed: `scan.zig` line 127 `-= 1` made `-= 2`, which
# panics inside `boot_tests.zig`'s own number tests; `parser.zig` line 134's
# `container` default flipped, which makes the generator fail to parse
# `boot.janet`; and `ev.zig` line 143's `windows` comparison inverted, which is
# a real compile error and prints no bare ` failure` line at all.
#
# Phase 20 batch 2c is why this exists. `parser.zig` and `scan.zig` are what
# the generator parses and scans with, and 214 of their 507 mutants died in it
# and were tallied as `uncompilable` -- a verdict that says the sweep reached
# nothing when in fact the strongest catcher in the batch had reached them.
(defn- bootstrap-failed
  "Why a run step of the build failed, or nil where the compiler is what refused."
  [text]
  (def lines (string/split "\n" text))
  (when-let [at (find-index |(and (string/find "run " $)
                                  (string/has-suffix? " failure" $)
                                  (not (string/has-suffix? " transitive failure" $)))
                            lines)]
    (def after (drop (+ at 1) lines))
    (def why (or (find |(or (string/find "panic:" $)
                            (string/find "error" (string/ascii-lower $)))
                       after)
                 (find |(not (empty? (string/trim $))) after)))
    # A Zig panic leads with the thread id that took it, which is a different
    # number every run. Left in, the tally row is unique per mutant and the
    # column stops aggregating -- which is the one thing the catcher column is
    # for. The rest of the line is what names the mutant's death.
    (def trimmed (string/trim (or why "")))
    (brief (if (string/has-prefix? "thread " trimmed)
             (if-let [at (string/find " panic:" trimmed)]
               (string/slice trimmed (+ at 1))
               trimmed)
             trimmed))))

(defn- suite-failed [r]
  (cond
    (r :timeout) "hang"
    (let [text (tools/both r)]
      (or (not= 0 (r :code))
          (string/find "✘" text)
          (not (string/find "tests passed" text))))
    "fail"))

(defn- force-rm
  "Remove `path`, restoring as it descends the permission needed to descend.

  A suite that fails leaves its files at whatever mode it had set, and Phase 10
  Part 12's `unique.txt` at 0000 is the incident the debris list exists for. The
  mode has to depend on what the entry is: 0600 on a directory takes away the
  execute bit, so nothing inside it can be listed and the directory cannot be
  removed at all. A `tmp` left at 0600 that way is what made `suite-ev2` fail on
  unmutated source and catch four mutants that had not touched it."
  [path]
  (def mode (try (os/lstat path :mode) ([_] nil)))
  (when mode
    (try (os/chmod path (if (= mode :directory) 8r700 8r600)) ([_] nil))
    (when (= mode :directory)
      (each entry (try (os/dir path) ([_] []))
        (force-rm (string path "/" entry))))
    (tools/rm-rf path)))

(defn- clean-debris
  "Remove what a failing suite leaves in the working tree. See `debris`."
  []
  (each pattern debris
    (each path (tools/glob pattern)
      (force-rm path))))

(defn- suite-list
  "Every Janet suite, read from the directory rather than written down.

  A suite added to `test/` is judged from the run after it lands, which is what
  a list in this file could not promise."
  []
  (sort (seq [entry :in (try (os/dir "test") ([_] []))
              :when (and (string/has-prefix? "suite-" entry)
                         (string/has-suffix? ".janet" entry))]
          (string "test/" entry))))

# The names the driver reported `ok` for on unmutated source, in the order it
# ran them, filled in by the warm-up.
(var- contract-names @[])

(defn- contract-ok
  "The contract names this run of the driver reported `ok` for.

  The driver prints `<name> contract ok` as it finishes each one, and some add
  a count after it, so the name is what precedes the marker."
  [text]
  (def out @[])
  (each line (string/split "\n" text)
    (when-let [at (string/find " contract ok" line)]
      (array/push out (string/trim (string/slice line 0 at)))))
  out)

(defn- contract-catcher
  "The first contract the driver did not report `ok` for.

  On a failure that is the one that failed; on a hang it is the one after the
  last that finished, which is the one still running. The driver reports every
  contract it runs, in one shape, so the name is exact rather than the next one
  that happened to print."
  [text]
  (def seen (tabseq [name :in (contract-ok text)] name true))
  (find |(not (seen $)) contract-names))

(defn- build-once []
  (refuse-if-disk-full
    (tools/sh (string "zig build " build-flags
                      " --cache-dir " cache " -p " prefix)
              :timeout build-bound)
    "zig build"))

(defn- twice
  "Run a bounded step, and run it again if it hit its bound.

  The result of the second attempt is the one the judge reads, as though the
  first had not happened, so a step starved past its bound is scored on what it
  does when it gets to finish. Both attempts' seconds stay on the log line.
  The reasons are at `build-bound` for the build and at `bound` for every other
  step; they are the same reason twice."
  [name thunk]
  (def r (timed name thunk))
  (if (r :timeout) (timed name thunk) r))

(defn- judge-default []
  (clean-debris)
  (label verdict
    (def r (twice "build" build-once))
    (when (r :timeout) (return verdict ["caught" "build (hang)"]))
    (unless (= 0 (r :code))
      (return verdict
              (if-let [why (bootstrap-failed (tools/both r))]
                ["caught" (string "bootstrap: " why)]
                ["uncompilable" ""])))

    # Nothing is run when this build installed what the unmutated one did,
    # because there is nothing for a test to catch and no later stage compiles
    # anything this one did not. The verdict is final here.
    (when (timed "digest" unchanged?) (return verdict ["no effect" ""]))

    (def smoke (twice "smoke"
                      (fn [] (tools/sh (string prefix "/bin/wattle -e '(print (+ 1 2))'")
                                       :timeout bound))))
    (when (or (not (tools/ok? smoke)) (not= "3" (string/trim (smoke :out))))
      (return verdict ["caught" "startup"]))

    # The contract runs from the driver `zig build` just installed. It was a
    # shallow `zig cc` of `test/contracts.c` plus the contract against
    # `libwattle.a` until Phase 11 Part 22 deleted the C driver, and that line
    # would have failed for *every* mutant afterwards -- which this scores as
    # "caught", so the sweep would have reported a perfect score and measured
    # nothing. Rule 47's trap, in the same file it was found in last time, and
    # armed by a deleted file rather than a deleted flag.
    #
    # It is also why the check below is the driver's exit status rather than a
    # link failing: a Zig contract cannot fail to link, and a configuration
    # that cannot compile one fails `zig build` above as "uncompilable".
    (def run (twice "contracts"
                    (fn [] (tools/sh (string prefix "/test/wattle-contract-test")
                                     :timeout bound))))
    (def missed (contract-catcher (tools/both run)))
    (when (run :timeout)
      (return verdict ["caught" (string "contract (hang): " (or missed "?"))]))
    (unless (= 0 (run :code))
      (return verdict ["caught" (string "contract: " (or missed "?"))]))

    (each suite (suite-list)
      (when-let [why (suite-failed (twice (string "suite:" (last (string/split "/" suite)))
                                          (fn [] (tools/sh (string prefix "/bin/wattle " suite)
                                                           :timeout bound))))]
        (return verdict
                ["caught" (string/format "%s (%s)" (last (string/split "/" suite)) why)])))
    [nil ""]))

(defn- judge-full []
  (clean-debris)
  (def r (twice "full"
                (fn [] (refuse-if-disk-full
                         (tools/sh (string "zig build test " build-flags
                                           " --cache-dir " cache " -p " prefix)
                                   :timeout 1800)
                         "zig build test"))))
  (cond
    (r :timeout) ["caught" "full test (hang)"]
    (not= 0 (r :code))
    (let [text (tools/both r)
          first-line (find |(or (string/find "✘" $)
                                (string/find "assert" (string/ascii-lower $))
                                (string/find "error:" $))
                           (string/split "\n" text))]
      ["caught" (string "full test: " (brief (or first-line "")))])
    [nil ""]))

(def- stages {"default" judge-default "full" judge-full})
(def- stage-order ["default" "full"])

(defn- judge
  "Put a mutant through as little as will kill it.

  The first stage to reach a verdict ends the run, `no effect` included: the
  section comparison is made once, after the default build, and is final."
  [stage]
  (def order (if (= stage "auto") stage-order [stage]))
  (set digest-timeout false)
  (array/clear steps)
  (label done
    (each name order
      (def [verdict catcher] ((stages name)))
      (when verdict (return done [verdict catcher])))
    ["SURVIVED" ""]))

(defn- require-tools
  "Stop before the first build if the section comparison cannot be made."
  []
  (each tool ["otool" "shasum"]
    (unless (tools/ok? (tools/sh (string "command -v " tool) :timeout 30))
      (tools/die (string "\nABORT: " tool " is not on PATH.\n")
                 "The judge compares the sections of each built Mach-O file "
                 "against the ones\nunmutated source produced, and without "
                 tool " it cannot tell a mutant that\nchanged no code from one "
                 "no test caught. Both verdicts would be wrong."))))

# One marker per working session, which is the refcount the operator's session
# hooks keep: `$HOME/.claude/run/busy/<id>` exists while that session is
# working, and sleep goes back on only when the last one is gone. The sweep
# joins the same scheme under its own pid rather than inventing a second one,
# so a sweep and a session cannot switch sleep back on underneath each other.
# See the header.
(def- busy-dir (string (os/getenv "HOME") "/.claude/run/busy"))
(def- busy-marker (string busy-dir "/mutate-" (os/getpid)))

# The two invocations the operator's passwordless rule allows, spelled the way
# it spells them. `-n` so a host without the rule fails at once rather than
# waiting on a password nobody is there to type.
(defn- pmset-sleep
  "Set the idle-sleep minutes, answering whether it took."
  [minutes]
  (def r (tools/sh (string "sudo -n /usr/bin/pmset -a sleep " minutes) :timeout 10))
  (and (not (r :timeout)) (= 0 (r :code))))

(defn- hold-sleep-off
  "Place this run's marker and disable idle sleep, and say which happened.

  Every failure is swallowed. A sweep that cannot reach the power setting is a
  sweep whose seconds are unreliable, which is worth a line of warning and is
  not worth refusing to run over."
  []
  (def placed (try (do (os/mkdir busy-dir) (spit busy-marker "") true)
                ([_] (try (do (spit busy-marker "") true) ([_] false)))))
  (if (and placed (pmset-sleep 0))
    (print "power: idle sleep held off, marker " busy-marker)
    (print "power: WARNING could not hold idle sleep off; this host may sleep "
           "under the run and every bound will be a wall clock across the nap")))

(defn- release-sleep
  "Remove this run's marker, and restore idle sleep if no session still holds one.

  The emptiness test is what keeps a finishing sweep from switching sleep back
  on under a session that is still working, and it is the same test the hooks
  make."
  []
  (try (os/rm busy-marker) ([_] nil))
  (when (empty? (try (os/dir busy-dir) ([_] ["held"])))
    (pmset-sleep 1)))

(defn- abort
  "Release this run's marker, then print to stderr and exit as `tools/die` does.

  An exit does not run the `defer` that reaches `release-sleep`, so every abort
  after `hold-sleep-off` comes through here."
  [& parts]
  (release-sleep)
  (tools/die ;parts))

(defn- rebaseline
  "Build the restored tree once and add what that build left in the cache to `keep`.

  Run between two sources, after the first is restored and before the second's
  first mutant. See the call for why the warm-up's snapshot is not enough."
  [keep after]
  (def r (tools/sh (string "zig build " build-flags " --cache-dir " cache " -p " prefix)
                   :timeout build-bound))
  (unless (tools/ok? r)
    (abort (string/format "\nABORT: the unmutated build after %s fails.\n" after)
           "The source was restored, so the tree should build as it did at "
           "warm-up.\n\n"
           (if (r :timeout) "timed out" (tools/tail (tools/both r) 1200))))
  (def before (length keep))
  (eachk entry (cache-entries) (put keep entry true))
  (printf "baseline: rebuilt after %s, %d cache entries added" after (- (length keep) before))
  (:flush stdout))

(defn- warm-up
  "Build the unmutated source, and record what that produced.

  Three things come out of it: the cache entries an unmutated build leaves,
  which is the only exact discriminator for what a mutant added; the section
  digests the build installs, which is what says a mutant changed no code; and
  the contract names the driver reports, which is what names the catcher.

  It doubles as the precondition check: if a stage, the contract driver or any
  suite fails here the tree is not green and no verdict the sweep produces
  would mean anything."
  [stage-names]
  (clean-debris)
  (def builds {"default" "zig build" "full" "zig build test"})
  # `zig build` runs whatever stage the judge is pinned to, because it is what
  # fills the prefix, and the prefix is what the contract driver, the suites
  # and the section comparison all read. `zig build test` fills nothing: it
  # installed zero files into an empty prefix and left all twelve unchanged in
  # a full one. So `--stage full` needs this build even though it never runs
  # one of its own.
  (def to-build (if (has-value? stage-names "default")
                  stage-names
                  ["default" ;stage-names]))
  (each stage to-build
    (prin "baseline: " (builds stage) " ... ")
    (:flush stdout)
    (def began (os/clock))
    (def r (tools/sh (string (builds stage) " " build-flags
                             " --cache-dir " cache " -p " prefix)
                     :timeout 2400))
    (unless (tools/ok? r)
      (tools/die (string/format "\nABORT: `%s` fails on unmutated source.\n"
                                (builds stage))
                 "The tree is not green, so every verdict this sweep could "
                 "produce would be\nmeaningless. Fix that first.\n\n"
                 (if (r :timeout) "timed out" (tools/tail (r :err) 1200))))
    (when (= stage "default")
      (set baseline (digests))
      (unless baseline
        (tools/die (string/format "\nABORT: no Mach-O sections found under %s.\n" prefix)
                   "The section comparison is what separates a mutant that "
                   "changed no code from\na survivor, and it has nothing to "
                   "compare.")))
    (printf "ok (%.0fs%s)" (- (os/clock) began)
            (if (= stage "default")
              (string/format ", %d sections" (length baseline))
              "")))
  (def run (tools/sh (string prefix "/test/wattle-contract-test") :timeout bound))
  (unless (tools/ok? run)
    (tools/die "\nABORT: the contract driver fails on unmutated source.\n"
               "Every mutant would be scored as caught by it. Fix that first."))
  (set contract-names (contract-ok (tools/both run)))

  # Every suite runs for every mutant now, so every suite is a precondition. A
  # suite that fails here is recorded as the catcher for every mutant after it,
  # which is the failure `mutation.md` spends its longest paragraph on, and it
  # costs four seconds to rule out.
  (def bad (filter |(suite-failed (tools/sh (string prefix "/bin/wattle " $) :timeout bound))
                   (suite-list)))
  (unless (empty? bad)
    (tools/die (string "\nABORT: " (string/join bad ", ") " fail on unmutated source.\n")
               "Every suite runs for every mutant, so a suite failing here is "
               "scored as the\ncatcher for every mutant after it and the sweep "
               "measures nothing. This is\nusually debris an earlier run left: "
               "look for a file or a directory in the\nworking tree that the "
               "suite cannot recreate."))
  (printf "baseline: %d contracts, %d suites" (length contract-names)
          (length (suite-list)))
  (def entries (cache-entries))
  (printf "baseline: %d cache entries, %.1f GB\n" (length entries) (cache-gb))
  entries)

(defn- options
  "Every value given for `name`, in the order the command line gives them.

  `--src` is repeatable, because Part 2 runs the sweep as batches of two or
  three hours rather than as one run of thirty."
  [argv name]
  (def found @[])
  (for i 0 (length argv)
    (def arg (argv i))
    (cond
      (and (= arg name) (< (+ i 1) (length argv))) (array/push found (argv (+ i 1)))
      (string/has-prefix? (string name "=") arg)
      (array/push found (string/slice arg (+ 1 (length name))))))
  found)

(defn- option
  "The value given for `name`, or nil. The last wins if it is given twice."
  [argv name]
  (last (options argv name)))

(defn- site-set
  "The site indices an `--only` value names, as a set."
  [text]
  (def out @{})
  (each n (string/split "," text)
    (def index (scan-number n))
    (unless index (tools/die (string "mutate.janet: --only takes indices, got " text)))
    (put out (math/trunc index) true))
  out)

(defn- selections
  "Each `--src` in the order given, with the sites the `--only` after it names.

  An `--only` binds to the `--src` before it, so one run re-runs the survivors
  of several sources under one warm-up, one marker and one log. A `--src` with
  no `--only` after it sweeps every site. An `--only` before any `--src`, a
  second `--only` for the same `--src`, or a flag with no value stops the run."
  [argv]
  (def out @[])
  (var i 0)
  (while (< i (length argv))
    (def arg (argv i))
    (def [name value step]
      (cond
        (or (= arg "--src") (= arg "--only")) [arg (get argv (+ i 1)) 2]
        (string/has-prefix? "--src=" arg) ["--src" (string/slice arg 6) 1]
        (string/has-prefix? "--only=" arg) ["--only" (string/slice arg 7) 1]
        [nil nil 1]))
    (when (and name (nil? value))
      (tools/die (string "mutate.janet: " name " needs a value")))
    (case name
      "--src" (array/push out @{:src value})
      "--only" (let [pick (last out)]
                 (unless pick
                   (tools/die "mutate.janet: --only names sites in the --src before it, and there is none"))
                 (when (pick :only)
                   (tools/die (string "mutate.janet: two --only for " (pick :src))))
                 (put pick :only (site-set value))))
    (+= i step))
  out)

(defn- zig-sources
  "Every `.zig` file under `src/`, in path order."
  []
  (def out @[])
  (defn walk [dir]
    (each entry (sort (try (os/dir dir) ([_] [])))
      (def path (string dir "/" entry))
      (case (try (os/lstat path :mode) ([_] nil))
        :directory (walk path)
        :file (when (string/has-suffix? ".zig" entry) (array/push out path)))))
  (walk "src")
  out)

(defn- sweep-order
  "Every source with at least one site, the two never swept first.

  `ev/stream.zig` and `ev/backend.zig` lead because no sweep has run either to
  completion, and a run that dies eight hours in should have spent those hours
  on the sources whose verdicts are missing rather than on the ones already
  read. The rest follow in path order, so a resumed run and a fresh one visit
  them in the same sequence."
  [in-strings]
  (def lead ["src/runtime/ev/stream.zig" "src/runtime/ev/backend.zig"])
  (def rest (filter |(not (has-value? lead $)) (zig-sources)))
  (filter |(not (empty? (sites (string/split "\n" (string (slurp $))) in-strings)))
          [;(filter |(os/lstat $) lead) ;rest]))

(defn- read-log
  "The `source` and index of every verdict a log already holds."
  [path]
  (def seen @{})
  (each line (string/split "\n" (or (try (slurp path) ([_] nil)) ""))
    (def fields (string/split "\t" line))
    (when (>= (length fields) 2)
      (put seen (string (fields 0) "\t" (fields 1)) true)))
  seen)

(defn- stamp
  "The wall-clock moment in UTC, so a slow run can be lined up against the
  machine.

  `os/date`'s second argument selects local time, and passing it while printing
  a `Z` was wrong on any host that is not on UTC: every log written before
  2026-09-10 carries local time under a `Z`, off by the host's offset in one
  direction, so an interval computed inside one of those logs is right and a
  stamp lined up against `pmset` or `ps` is not."
  []
  (def d (os/date (os/time)))
  (string/format "%04d-%02d-%02dT%02d:%02d:%02dZ"
                 (d :year) (+ 1 (d :month)) (+ 1 (d :month-day))
                 (d :hours) (d :minutes) (d :seconds)))

(defn- report
  "The tally, the line that re-runs each source's survivors, and one line that
  re-runs them all where more than one source has any.

  The re-run line carries `--no-strings` when the run did, because a site
  index is a position in an enumeration that flag changes: without it, a
  pasted line names different sites in every source that has a string-literal
  site. Phase 20 Part 3e lost twenty-one verdicts to that and part_03d's
  `peg.zig` closures were re-verified because of it."
  [title tally survivors elapsed in-strings]
  (printf "--- %s %.0fs" title elapsed)
  (each key (sort (keys tally))
    (printf "%-34s %d" key (tally key)))
  (def strings-flag (if in-strings "" " --no-strings"))
  (def parts @[])
  (each src (sort (keys survivors))
    (def ns (survivors src))
    (unless (empty? ns)
      (def only (string/join (map string ns) ","))
      (array/push parts (string " --src " src " --only " only))
      (printf "  ./res/testing/mutate.janet --src %s%s --only %s"
              src strings-flag only)))
  # The whole round as one invocation, which holds one marker from its
  # warm-up to its exit. See the header on why the lines above are not to be
  # chained.
  (when (> (length parts) 1)
    (printf "  one run: ./res/testing/mutate.janet%s%s" strings-flag (string/join parts)))
  (:flush stdout))

(defn- usage []
  (print "usage: mutate.janet --src <file> [--only 3,17] [--src <file> [--only 5] ...] | --all")
  (print "       [--stage auto|default|full] [--list]")
  (print "       [--log <file>] [--resume <file>] [--strings|--no-strings]")
  (print)
  (print "--src is repeatable and sweeps the sources in the order given, under")
  (print "one warm-up and one log; that is the batch Part 2 runs. --all sweeps")
  (print "every source under src/ and is thirty hours. Neither form is the")
  (print "default, so no sweep starts from the program's name alone.")
  (print)
  (print "--only names sites in the --src before it, so a round of re-runs over")
  (print "several sources is one invocation. A --src with no --only after it")
  (print "sweeps every site.")
  (print)
  (print "Launching one in the background under zsh needs `unsetopt BG_NICE`")
  (print "first, or the run is niced 5 and starved by anything else on the")
  (print "host. Check with `ps -o pid,ni,stat -p <pid>`; it should read NI 0.")
  (print)
  (print "The run disables idle sleep for itself and restores it on the way")
  (print "out, because an unattended sweep looks idle and a host that sleeps")
  (print "under it measures every bound across the nap. A run killed with")
  (print "SIGKILL leaves its marker in ~/.claude/run/busy and sleep disabled;")
  (print "remove the marker by hand, along with the usual `git status`.")
  (os/exit 2))

(defn main [& argv]
  (os/cd tools/root)
  (def named (selections argv))
  (def all (has-value? argv "--all"))
  (def stage (or (option argv "--stage") "auto"))
  (def log-path (option argv "--log"))
  (def resume-path (option argv "--resume"))
  (def listing (has-value? argv "--list"))
  (unless (or (not (empty? named)) all) (usage))
  (when (and (not (empty? named)) all)
    (tools/die "mutate.janet: --src and --all are alternatives"))
  (unless (or (= stage "auto") (stages stage))
    (tools/die "mutate.janet: --stage must be auto, default or full"))

  # 207 of the 5,415 sites are words inside a literal on a code line, most of
  # them docstrings. They are their own pass, so a whole-tree run leaves them
  # out unless asked; one source at a time keeps them, which is how the three
  # that found `assert-error` comparing nothing were noticed.
  (def in-strings
    (if all
      (has-value? argv "--strings")
      (not (has-value? argv "--no-strings"))))

  (def picks (if all (map (fn [src] @{:src src}) (sweep-order in-strings)) named))
  (def sources (map |($ :src) picks))

  (when listing
    (each src sources
      (def lines (string/split "\n" (string (slurp src))))
      (def all-sites (sites lines in-strings))
      (printf "%d mutation sites in %s" (length all-sites) src)
      (for n 0 (length all-sites)
        (def site (all-sites n))
        (printf "%4d line %-5d %-12s %s" n (+ (site 0) 1) (site 4)
                (tools/head (string/trim (lines (site 0))) 70))))
    (os/exit 0))

  (def done (if resume-path (read-log resume-path) @{}))

  (require-tools)
  (def totals @{})
  (def survivors @{})
  (def started (os/clock))
  (tools/rm-rf cache)
  (def stage-names (if (= stage "auto") stage-order [stage]))
  (def keep (warm-up stage-names))
  # After the warm-up rather than before it, because `tools/die` exits and an
  # exit does not run the `defer` below: a warm-up that finds the tree not
  # green would leave the marker behind and sleep switched off with no sweep
  # running. The warm-up's own two builds go unprotected, which costs a nap in
  # the baseline timings and nothing in the verdicts.
  (hold-sleep-off)
  (printf "sweeping %d source%s" (length sources) (if (= 1 (length sources)) "" "s"))

  # Whichever source currently holds a mutation, so the restore on the way out
  # reaches it whether the run ended, died or was killed mid-source.
  (var mutated nil)
  (var pristine nil)

  (defn restore []
    (when mutated
      (spit mutated pristine)
      (unless (= (string (slurp mutated)) pristine)
        (print "WARNING: " mutated " did not restore cleanly -- check it by hand")))
    (tools/rm-rf cache)
    (tools/rm-rf prefix)
    (release-sleep))

  (defer (restore)
    (each pick picks
      (def src (pick :src))
      (def only (pick :only))
      (def original (string (slurp src)))
      (def lines (string/split "\n" original))
      (def all-sites (sites lines in-strings))
      (set mutated src)
      (set pristine original)
      (def tally @{})
      (def mine @[])
      (def began (os/clock))
      (printf "\n=== %s: %d sites" src (length all-sites))
      (:flush stdout)

      (for n 0 (length all-sites)
        (when (and (or (nil? only) (only n))
                   (not (done (string src "\t" n))))
          (when (< (tools/free-gb "/tmp") min-free-gb)
            (prune keep)
            (when (< (tools/free-gb "/tmp") min-free-gb)
              (spit src original)
              (abort (string/format
                       "\nABORT: %.0fGB free at %s mutant %d, below the %dGB floor.\n"
                       (tools/free-gb "/tmp") src n min-free-gb)
                     "Pruning the sweep cache did not recover enough. Stopping "
                     "here rather than\nletting builds fail for want of disk and "
                     "recording that as a verdict.\nSource restored.")))

          (def text (apply-mutation lines (all-sites n)))
          (spit src text)
          (def at (os/clock))

          (def outcome
            (try (judge stage)
              ([e]
                (when (and (dictionary? e) (e :out-of-space))
                  (spit src original)
                  (abort (string/format
                           "\nABORT: the volume filled while %s mutant %d was being judged.\n%s\n\n"
                           src n (e :out-of-space))
                         "This is the failure the floor exists to prevent, caught "
                         "where it actually\nhappens rather than guessed at beforehand: a "
                         "build that fails for want of\ndisk looks exactly like a mutant "
                         "that failed to compile. Source restored."))
                (error e))))
          (def [verdict catcher] outcome)
          (def seconds (- (os/clock) at))
          (prune keep)

          # See the header. The window that matters is this whole judged run,
          # not the instant after the write: the edit that broke Part 10's
          # first sweep landed while a build was in flight. So the check comes
          # *after* the verdict, and voids it.
          (unless (= (string (slurp src)) text)
            (spit src original)
            (abort (string/format
                     "\nABORT: %s changed while mutant %d was being judged.\n" src n)
                   "Something else wrote the file -- an editor, a bulk sed, a "
                   "rename.\nThat verdict, and any after it, would be a lie. "
                   "Source restored; re-run from the start."))

          (each t [tally totals]
            (put t verdict (+ 1 (get t verdict 0)))
            (unless (empty? catcher)
              (def key (string "by:" catcher))
              (put t key (+ 1 (get t key 0)))))
          (def site (all-sites n))
          (printf "%4d %-14s line %-5d %-12s %s%s"
                  n verdict (+ (site 0) 1) (site 4) catcher
                  (if (= verdict "SURVIVED")
                    (string "   |" (tools/head (string/trim (lines (site 0))) 70))
                    ""))
          # A stalled digest is announced rather than left to the log. It
          # cannot have produced `no effect`, because a timed-out digest
          # answers nil and nil never matches the baseline, so what it costs
          # is a verdict decided by running the tests instead of by comparing.
          (when digest-timeout
            (printf "     WARNING: the digest for %s mutant %d hit its bound; this verdict was decided by the tests"
                    src n))
          (:flush stdout)
          (when (= verdict "SURVIVED") (array/push mine n))

          # Appended as the verdict is decided rather than at the end, because
          # the log is what a killed run resumes from.
          (when log-path
            (def handle (file/open log-path :a))
            (when handle
              # The first seven fields are what `--resume` reads and what an
              # older log holds. What follows them is for locating a stall:
              # the moment, the cost of each step in the order it ran, and
              # whether the digest hit its bound. The last field is the
              # enumeration the index in field two belongs to, because the
              # same index names a different site under each, and a log read
              # weeks later says nothing about which flag produced it.
              (file/write handle
                          (string/format "%s\t%d\t%s\t%s\t%d\t%s\t%.1f\t%s\t%s\t%s\t%s\n"
                                         src n verdict catcher (+ (site 0) 1)
                                         (site 4) seconds (stamp) (step-costs)
                                         (if digest-timeout "digest-timeout" "")
                                         (if in-strings "strings" "no-strings")))
              (file/flush handle)
              (file/close handle)))))

      # Restored before the next source is touched, so only one source in the
      # tree ever holds a mutation.
      (spit src original)
      (unless (= (string (slurp src)) original)
        (abort (string/format "\nABORT: %s did not restore cleanly.\n" src)
               "Every verdict after this one would be judged against a "
               "mutated tree."))
      (put survivors src mine)
      (report src tally {src mine} (- (os/clock) began) in-strings)

      # The keep set is the warm-up's snapshot of the cache, and the snapshot
      # alone is not enough. A source restored byte for byte builds the image
      # generator under a fresh digest, an entry outside the snapshot, and the
      # next source's first prune deletes it while the image step's manifest
      # still names it. A source whose mutants leave the generator alone then
      # hits that manifest on every build and fails the cache check: 47 of
      # `native_module.zig`'s 48 verdicts in Phase 20 batch 2i were that
      # failure, scored as bootstrap catches. So the restored tree is built
      # once here, before the next source's first mutant, and every entry that
      # build leaves is kept.
      (unless (= pick (last picks)) (rebaseline keep src)))
    (set mutated nil))

  (report "TOTAL" totals survivors (- (os/clock) started) in-strings)
  (os/exit 0))
