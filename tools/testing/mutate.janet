#!/usr/bin/env janet
# Mutation sweep over one Zig subsystem source.
#
# Development instrument in `tools/`. Set the
# three constants below to the increment's own subject; that is the only
# per-increment edit it needs.
#
#     ./tools/testing/mutate.janet                 # every site, escalating judge
#     ./tools/testing/mutate.janet --only 3,17,64  # just these, e.g. a second pass
#     ./tools/testing/mutate.janet --stage full    # skip the cheap stages
#
# ## The judge escalates, because most mutants die cheaply
#
# A default `zig build` does not reach every half of every subsystem.
# `janet_native`'s success path is reached only by `test/zig-native.janet`, which
# only the build step runs. So a mutant is put through as little as will kill it:
#
#     default   zig build, then startup, the contract, and the suites
#     full      zig build test, the whole graph
#
# A mutant that survives both is a survivor. `--stage` pins the judge to one of
# them when you already know which is the interesting one.
#
# **There was a third stage and it is gone, along with its reason.** `boot` built
# `-Dboot=zig` and re-ran startup and the suites, because `janet_core_env` has a
# bootstrap implementation that only the image generator compiles and the
# generator was C by default -- so a mutation to the Zig bootstrap half was not
# compiled by `default` at all. Phase 10 Part 17g removed `-Dboot` by removing
# the C generator: every `zig build` now builds `janet-boot` from the same Zig
# sources, because that is the only thing that can emit an image. `default`
# therefore compiles what `boot` was added to reach, and Phase 11 Part 10's
# lesson 26 is the evidence -- two mutations to `value_wrap.zig` broke the
# *bootstrap*, under a plain `zig build`, and the build failed at `run exe
# janet-boot`.
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
# ## READ THIS BEFORE THE NEXT FULL SWEEP
#
# **Three things are known wrong with this instrument and none of them is
# fixed.** They are listed here, printed by the tool itself at the start of
# every judging run, and repeated in `AGENTS.md` -- three places, because this
# tool has been repaired twice and executed zero times, and because a paragraph
# has already failed to prevent this class of mistake more than once.
#
# 1. **The contract call is bounded at 600 seconds where a suite gets 12.**
#    `judge-default` passes `:timeout 600` at the `janet-zig-contract-test`
#    line. A mutant that hangs the contract therefore costs fifty times one
#    that hangs a suite, for a program that normally returns in well under a
#    second. `ev/backend.zig` *is* the event loop, so contract hangs are not
#    the exception there: the gate's sample of that source did not finish, and
#    186 sites with even a tenth of them hanging is over three hours on that
#    source alone. This has now cost two runs -- the gate's, and Part 29's own
#    verdict probe, which was killed at ten minutes and left the tree mutated.
#    `ev/with-deadline` is already inside `tools/sh`, so the fix is one
#    argument.
#
# 2. **A site this configuration does not compile is scored SURVIVED rather
#    than as no effect.** Three of the gate's nine survivors were
#    `WSAGetLastError` and `GetLastError` inside Windows arms this host does
#    not compile -- 20% of that window was noise. Compare the built binary's
#    **text section**, not the file: debug info carries line and column
#    numbers, so a mutant that changes a line's length produces a different
#    file with identical code, which is exactly the case this is meant to
#    catch. `phase_11.md`'s rule 74 has the measurement (2,789,788 bytes).
#
# 3. **Then run `ev/stream.zig` and `ev/backend.zig` to completion**, which no
#    sweep has ever done. The 16.4s-a-mutant figure holds only for the first,
#    where nothing hung.
#
# Phase 11 Part 29 replaced the Python with this and deliberately changed
# nothing else: each of the three alters what a verdict *means*, and the phase
# that owns the sweep should own them. `phase_11.md`'s gate reading has the
# measurements and rule 83 the argument.

(import ../common :as tools)

### per-increment

# Phase 10 Part 13: the event loop. Four sources behind one selector, so the
# sweep is run four times with `--src`; `contract` and `suites` are the same
# for all four.
(def src-default "src/runtime/ev.zig")
(def contract "ev_loop")
# Three rather than six, and the trim is a measurement rather than a taste.
# A mutant that breaks the loop *hangs* every suite it reaches, at `bound`
# seconds each, so the cost of a suite list is set by the survivors and the
# slow catches rather than by the fast ones. `suite-ev` has 742 assertions and
# is the subject; `suite-ev2` covers threads and `suite-io` covers the streams
# `os/spawn` builds. `suite-os`, `suite-net` and `suite-marsh` were in the list
# and caught nothing the first three did not, at roughly twice the wall clock.
# The escalating judge still ends at the whole `zig build test` graph, so
# nothing is out of reach -- only out of the cheap path.
(def suites
  ["test/suite-ev.janet"
   "test/suite-ev2.janet"
   "test/suite-io.janet"])

### discipline

(def cache "/tmp/janet-mutate-cache")
(def prefix "/tmp/janet-mutate-out")

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
(def debris ["unique.txt" "janet-suite-*" "tmp/osprobe*" "ev-*.txt"])
(def bound 12)          # seconds per judged run; a hang counts as caught
# Below this the sweep prunes, then gives up. Lowered from 20 in Phase 10 Part
# 13, because on macOS the number this reads is the wrong one: `statvfs`
# reports what is free *now* and knows nothing about purgeable space, which the
# OS hands back the moment a write needs it. Measured on that machine mid-sweep:
#
#     available (plain statvfs)      28.2 GB   <- what this check sees
#     available for important usage 143.3 GB   <- what the OS will actually give
#
# So the floor was aborting runs with over a hundred gigabytes available. The
# guard still earns its place -- an ENOSPC mid-build is indistinguishable from
# a mutant that failed to compile, and gets recorded as one -- but it should be
# a backstop rather than the binding constraint.
#
# Note this is safe to change mid-chain and `suites` is not: this decides
# whether the run continues, not what any mutant's verdict is.
(def min-free-gb 10)

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
  `--no-strings` to leave them alone."
  [lines in-strings]
  (def out @[])
  (for i 0 (length lines)
    (def line (lines i))
    (def stripped (string/trim line))
    (unless (or (string/has-prefix? "//" stripped)
                (string/has-prefix? "\"" stripped)
                (string/has-prefix? "++" stripped))
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

(defn- refuse-if-disk-full [r what]
  (when (and r (not (r :timeout)) (not= 0 (r :code)) (disk-full? (tools/both r)))
    (error {:out-of-space (string/format "%s reported the volume full:\n%s"
                                         what (tools/tail (string/trim (tools/both r)) 400))}))
  r)

(defn- suite-failed [r]
  (cond
    (r :timeout) "hang"
    (let [text (tools/both r)]
      (or (not= 0 (r :code))
          (string/find "✘" text)
          (not (string/find "tests passed" text))))
    "fail"))

(defn- clean-debris
  "Remove what a failing suite leaves in the working tree. See `debris`."
  []
  (each pattern debris
    (each path (tools/glob pattern)
      (try (os/chmod path 8r600) ([_] nil))
      (tools/rm-rf path))))

(defn- judge-default []
  (clean-debris)
  (label verdict
    (def r (refuse-if-disk-full
             (tools/sh (string "zig build --cache-dir " cache " -p " prefix) :timeout 600)
             "zig build"))
    (when (r :timeout) (return verdict ["caught" "build (hang)"]))
    (unless (= 0 (r :code)) (return verdict ["uncompilable" ""]))

    (def smoke (tools/sh (string prefix "/bin/janet -e '(print (+ 1 2))'") :timeout bound))
    (when (or (not (tools/ok? smoke)) (not= "3" (string/trim (smoke :out))))
      (return verdict ["caught" "startup"]))

    # The contract runs from the driver `zig build` just installed. It was a
    # shallow `zig cc` of `test/contracts.c` plus the contract against
    # `libjanet.a` until Phase 11 Part 22 deleted the C driver, and that line
    # would have failed for *every* mutant afterwards -- which this scores as
    # "caught", so the sweep would have reported a perfect score and measured
    # nothing. Rule 47's trap, in the same file it was found in last time, and
    # armed by a deleted file rather than a deleted flag.
    #
    # It is also why the check below is the driver's exit status rather than a
    # link failing: a Zig contract cannot fail to link, and a configuration
    # that cannot compile one fails `zig build` above as "uncompilable".
    (def run (tools/sh (string prefix "/bin/janet-zig-contract-test " contract)
                       :timeout 600))
    (when (run :timeout) (return verdict ["caught" "contract (hang)"]))
    (unless (= 0 (run :code)) (return verdict ["caught" "contract"]))

    (each suite suites
      (when-let [why (suite-failed (tools/sh (string prefix "/bin/janet " suite)
                                             :timeout bound))]
        (return verdict
                ["caught" (string/format "%s (%s)" (last (string/split "/" suite)) why)])))
    [nil ""]))

(defn- judge-full []
  (clean-debris)
  (def r (refuse-if-disk-full
           (tools/sh (string "zig build test --cache-dir " cache " -p " prefix) :timeout 1800)
           "zig build test"))
  (cond
    (r :timeout) ["caught" "full test (hang)"]
    (not= 0 (r :code))
    (let [text (tools/both r)
          first-line (find |(or (string/find "✘" $)
                                (string/find "assert" (string/ascii-lower $))
                                (string/find "error:" $))
                           (string/split "\n" text))]
      ["caught" (string "full test: "
                        (if first-line
                          (let [t (string/trim first-line)]
                            (if (> (length t) 70) (string/slice t 0 70) t))
                          ""))])
    [nil ""]))

(def- stages {"default" judge-default "full" judge-full})
(def- stage-order ["default" "full"])

(defn- judge [stage]
  (def order (if (= stage "auto") stage-order [stage]))
  (label done
    (each name order
      (def [verdict catcher] ((stages name)))
      (when verdict (return done [verdict catcher])))
    ["SURVIVED" ""]))

(defn- announce-prerequisites
  `Print what is known wrong with this instrument, before it is believed.

  The header says all of this and AGENTS.md repeats it, and neither is where
  somebody stands when they start a three-hour run. build.zig puts the argument
  better than this docstring can: a check that runs before the first build is
  worth more than a paragraph that runs before the first mistake. These are
  open decisions rather than mistakes, so it is a banner and not a refusal --
  but it goes in the same place.`
  []
  (eprint)
  (eprint "  ---- mutate.janet: three known defects, none of them fixed ----")
  (eprint "  1. the contract call is bounded at 600s where a suite gets " bound "s.")
  (eprint "     a mutant that hangs the contract costs 50x one that hangs a suite;")
  (eprint "     this has already cost two runs. tools/sh takes :timeout.")
  (eprint "  2. a site this configuration does not compile scores SURVIVED, not")
  (eprint "     `no effect`. compare the built TEXT SECTION, not the file.")
  (eprint "  3. no sweep has ever run to completion -- ev/backend.zig especially.")
  (eprint "  this file's header has the detail; also AGENTS.md, and phase_11.md")
  (eprint "  rules 74 and 83.")
  (eprint "  ---------------------------------------------------------------")
  (eprint))

(defn- warm-up
  "Build the unmutated source once per stage, and snapshot what that leaves.

  Doubles as the precondition check: if a stage fails here the tree is not
  green and no verdict the sweep produces would mean anything."
  [src original stage-names]
  (spit src original)
  (def builds {"default" "zig build" "full" "zig build test"})
  (each stage stage-names
    (prin "baseline: " (builds stage) " ... ")
    (:flush stdout)
    (def began (os/clock))
    (def r (tools/sh (string (builds stage) " --cache-dir " cache " -p " prefix)
                     :timeout 2400))
    (unless (tools/ok? r)
      (tools/die (string/format "\nABORT: `%s` fails on unmutated source.\n"
                                (builds stage))
                 "The tree is not green, so every verdict this sweep could "
                 "produce would be\nmeaningless. Fix that first.\n\n"
                 (if (r :timeout) "timed out" (tools/tail (r :err) 1200))))
    (printf "ok (%.0fs)" (- (os/clock) began)))
  (def entries (cache-entries))
  (printf "baseline: %d cache entries, %.1f GB\n" (length entries) (cache-gb))
  entries)

(defn- option [argv name]
  (var found nil)
  (for i 0 (length argv)
    (def arg (argv i))
    (cond
      (and (= arg name) (< (+ i 1) (length argv))) (set found (argv (+ i 1)))
      (string/has-prefix? (string name "=") arg)
      (set found (string/slice arg (+ 1 (length name))))))
  found)

(defn main [& argv]
  (os/cd tools/root)
  (def src (or (option argv "--src") src-default))
  (def only-arg (option argv "--only"))
  (def stage (or (option argv "--stage") "auto"))
  (unless (or (= stage "auto") (stages stage))
    (tools/die "mutate.janet: --stage must be auto, default or full"))
  (def no-strings (has-value? argv "--no-strings"))
  (def listing (has-value? argv "--list"))

  (def original (string (slurp src)))
  (def lines (string/split "\n" original))
  (def all-sites (sites lines (not no-strings)))
  (def only (when only-arg
              (let [t @{}]
                (each n (string/split "," only-arg)
                  (put t (math/trunc (scan-number n)) true))
                t)))

  (printf "%d mutation sites in %s" (length all-sites) src)
  (when listing
    (for n 0 (length all-sites)
      (def site (all-sites n))
      (printf "%4d line %-5d %-12s %s" n (+ (site 0) 1) (site 4)
              (tools/head (string/trim (lines (site 0))) 70)))
    (os/exit 0))

  # Before the warm-up, because the warm-up is a build and this should be the
  # first thing on the screen rather than the thing above a build log.
  (announce-prerequisites)

  (def tally @{})
  (def survivors @[])
  (def started (os/clock))
  (tools/rm-rf cache)
  (def stage-names (if (= stage "auto") stage-order [stage]))
  (def keep (warm-up src original stage-names))

  (defn restore []
    (spit src original)
    (unless (= (string (slurp src)) original)
      (print "WARNING: " src " did not restore cleanly -- check it by hand"))
    (tools/rm-rf cache)
    (tools/rm-rf prefix))

  (defer (restore)
    (label swept
      (for n 0 (length all-sites)
        (when (or (nil? only) (only n))
          (when (< (tools/free-gb "/tmp") min-free-gb)
            (prune keep)
            (when (< (tools/free-gb "/tmp") min-free-gb)
              (spit src original)
              (tools/die (string/format
                           "\nABORT: %.0fGB free at mutant %d, below the %dGB floor.\n"
                           (tools/free-gb "/tmp") n min-free-gb)
                         "Pruning the sweep cache did not recover enough. Stopping "
                         "here rather than\nletting builds fail for want of disk and "
                         "recording that as a verdict.\nSource restored.")))

          (def text (apply-mutation lines (all-sites n)))
          (spit src text)

          (def outcome
            (try (judge stage)
              ([e]
                (when (and (dictionary? e) (e :out-of-space))
                  (spit src original)
                  (tools/die (string/format
                               "\nABORT: the volume filled while mutant %d was being judged.\n%s\n\n"
                               n (e :out-of-space))
                             "This is the failure the floor exists to prevent, caught "
                             "where it actually\nhappens rather than guessed at beforehand: a "
                             "build that fails for want of\ndisk looks exactly like a mutant "
                             "that failed to compile. Source restored."))
                (error e))))
          (def [verdict catcher] outcome)
          (prune keep)

          # See the header. The window that matters is this whole judged run,
          # not the instant after the write: the edit that broke Part 10's
          # first sweep landed while a build was in flight. So the check comes
          # *after* the verdict, and voids it.
          (unless (= (string (slurp src)) text)
            (spit src original)
            (tools/die (string/format
                         "\nABORT: %s changed while mutant %d was being judged.\n" src n)
                       "Something else wrote the file -- an editor, a bulk sed, a "
                       "rename.\nThat verdict, and any after it, would be a lie. "
                       "Source restored; re-run from the start."))

          (put tally verdict (+ 1 (get tally verdict 0)))
          (unless (empty? catcher)
            (def key (string "by:" catcher))
            (put tally key (+ 1 (get tally key 0))))
          (def site (all-sites n))
          (printf "%4d %-14s line %-5d %-12s %s%s"
                  n verdict (+ (site 0) 1) (site 4) catcher
                  (if (= verdict "SURVIVED")
                    (string "   |" (tools/head (string/trim (lines (site 0))) 70))
                    ""))
          (:flush stdout)
          (when (= verdict "SURVIVED") (array/push survivors n))))))

  (printf "--- %.0fs" (- (os/clock) started))
  (each key (sort (keys tally))
    (printf "%-34s %d" key (tally key)))
  (unless (empty? survivors)
    (print "\nre-run the survivors with:\n  ./tools/testing/mutate.janet --only "
           (string/join (map string survivors) ",")))
  (os/exit 0))
