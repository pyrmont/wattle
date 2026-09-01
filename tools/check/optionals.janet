#!/usr/bin/env janet
# Every non-null assertion whose null the *same function* also tests.
#
# The shape is
#
#     if (x == null) { ... }        // or `!= null`, or `if (x) |y|`
#     ... x.? ...                   // in the same function body
#     ... x orelse unreachable ...  // and this counts too, for the reason below
#
# and the question at each one is whether the null is **a state the code
# handles** or **an invariant violation**. Phase 15 Part 2b's rule is that a
# `.?` survives only where it is the second kind, and there it is written
# `orelse unreachable` with the invariant named beside it -- never a bare `.?`.
#
# ## Why this is an instrument and not a count
#
# The plan's gate for 2b was a number: `.?` under 250 tree-wide. The tree has
# 929 occurrences over 60 files, three times what the plan assumed, and a
# number alone cannot say whether the ones left are the right ones -- an
# `orelse unreachable` is a claim nobody checks, and a `.?` rewritten as
# `if (x) |y|` *wrongly* still compiles. So the gate is restated the way Phase
# 14 Part 2 restated its cast gate: classify, and gate on the class that must
# be empty.
#
# **This finds the class that must be empty.** A function that tests `x` for
# null in one place and writes `x.?` in another is not asserting an invariant;
# it is contradicting itself, and one of the two is wrong. That is decidable by
# reading one function, which is what makes it a check rather than a judgement.
#
#   tested       the same function tests this receiver's null elsewhere.
#                **This class must be empty.**
#   accumulator  the receiver is a local `var x: ?T = null` in this same
#                function, so its null is "the first pass has not happened
#                yet" rather than a value that may be absent -- the test is
#                what *makes* the later assertion true. Not a contradiction.
#
# **A bare `orelse unreachable` is in the population; a named one is not.** It
# is the right outcome for a `.?` whose null cannot happen -- but a class that
# counted only `.?` could be emptied by respelling every row rather than by
# resolving one, and an instrument you can satisfy without doing the work is
# worse than no instrument. So the plan's own rule decides it: "`orelse
# unreachable` with the invariant named in a comment beside it -- never a bare
# `.?`". A comment on the line above is what clears the row, because a claim
# with a reason beside it is one a reader can disagree with and a bare one is
# not.
#
# ## What this does not see
#
#     ./tools/check/optionals.janet           regenerate tools/check/optionals.txt
#     ./tools/check/optionals.janet --check   fail if the tree disagrees with it
#
# A `.?` whose null is tested in a *different* function -- by the caller, or by
# a helper one level down -- is not in this inventory, and neither is one whose
# receiver is spelled differently at the two sites (`t.?` and `table.?` for the
# same value). It sees the contradiction a reader of one function would see,
# which is the population a per-file sweep can actually close.
#
# It also splits function bodies on a line beginning `fn`, `pub fn`,
# `inline fn` or their indented forms, so a nested `struct { fn ... }` reads as
# a function of its own. That is the intended granularity; a receiver captured
# by an enclosing function and unwrapped in a nested one is two entries, and
# both are worth reading.

(import ../common :as tools)

(def list-path "tools/check/optionals.txt")

(def receiver-peg
  ~{:name (some (+ :w "_"))
    :path (* :name (any (* "." :name)))
    :main :path})

(defn- unwrap-sites [body]
  ``Every place this body asserts a receiver is non-null: `x.?`, and
  `x orelse unreachable`.

  **Both forms count.** Naming the invariant is the right outcome for a `.?`
  whose null cannot happen -- but only when the same function is not *also*
  testing for that null. If it is, the contradiction is unchanged and the
  `orelse unreachable` has simply hidden it from a matcher that looked for one
  spelling.``
  (def out @[])
  (each i (string/find-all ".?" body) (array/push out i))
  # `orelse unreachable` counts only when the invariant is *not* named. The
  # plan's rule is "`orelse unreachable` with the invariant named in a comment
  # beside it -- never a bare `.?`", so a named one is the resolved state and a
  # bare one is a claim nobody checks. Which it is, is decided by whether the
  # line above it carries a comment; `strip-comments` blanks those, so a
  # commented line is one that is all spaces.
  (each i (string/find-all " orelse unreachable" body)
    (def line-start (or (last (string/find-all "\n" (string/slice body 0 i))) -1))
    (def prev-end line-start)
    (def prev-start (or (last (string/find-all "\n" (string/slice body 0 (max 0 prev-end)))) -1))
    (def previous (string/slice body (+ prev-start 1) (max 0 prev-end)))
    (unless (and (> prev-end 0) (empty? (string/trim previous)))
      (array/push out i)))
  (sort out))

(defn- receivers-unwrapped [body]
  "Every receiver path this body asserts non-null, with how many times."
  (def counts @{})
  (each i (unwrap-sites body)
    # Walk back over the receiver path immediately before the `.?`.
    (var j i)
    (while (and (> j 0)
                (let [b (get body (- j 1))]
                  (or (tools/word-byte? b) (= b (chr ".")))))
      (-- j))
    # A leading `.` is the tail of a longer expression the walk could not
    # cross -- `foo().name_prefix` -- and naming it `.name_prefix` would put a
    # row in the list that no reader can find. Drop it.
    (def path (string/slice body j i))
    (when (and (not (empty? path))
               (not (string/has-suffix? "." path))
               (not (string/has-prefix? "." path)))
      (put counts path (+ 1 (get counts path 0)))))
  counts)

(defn- receivers-tested [body]
  "Every receiver path whose null this body tests."
  (def seen @{})
  (each pat ["== null" "!= null"]
    (each i (string/find-all pat body)
      (var j i)
      (while (and (> j 0) (= (chr " ") (get body (- j 1)))) (-- j))
      (var k j)
      (while (and (> k 0)
                  (let [b (get body (- k 1))]
                    (or (tools/word-byte? b) (= b (chr ".")))))
        (-- k))
      (def path (string/slice body k j))
      (unless (empty? path) (put seen path true))))
  # `if (x) |y|` and `while (x) |y|` are the same test, spelled as a capture.
  (each pat ["if (" "while ("]
    (each i (string/find-all pat body)
      (def open (+ i (length pat)))
      (def close (string/find ")" body open))
      (when (and close (= (chr "|") (get body (+ close 2))))
        (def path (string/slice body open close))
        (when (peg/match ~(* ,receiver-peg -1) path) (put seen path true)))))
  seen)

(defn- locals-initialised-null [body]
  ``Receivers declared in this body as a local `var x: ?T = null`.

  Their null is the local's own progress -- "has the first pass happened yet"
  -- rather than a value that may be absent, and a function that both tests one
  and asserts it at the end is not contradicting itself: the test is what makes
  the assertion true. `structs.cfunStructToTable` is the type, and it is a
  different class rather than an exemption because the shape is decidable.``
  (def seen @{})
  (each i (string/find-all "var " body)
    (def eol (or (string/find "\n" body i) (length body)))
    (def decl (string/trim (string/slice body i eol)))
    (def m (peg/match ~(* "var " (<- (some (+ :w "_"))) ": ?" (some (if-not "=" 1)) "= null;" -1) decl))
    (when m (put seen (first m) true)))
  seen)

(defn- bodies-in [text]
  "Function bodies, as [name line body] -- split on a line that declares one."
  (def lines (string/split "\n" text))
  (def starts @[])
  (for i 0 (length lines)
    (def l (lines i))
    (def m (peg/match ~(* (any " ") (? "pub ") (? (+ "inline " "export " "noinline "))
                          "fn " (<- (some (+ :w "_"))))
                      l))
    (when m (array/push starts [i (first m)])))
  (def out @[])
  (for n 0 (length starts)
    (def [i name] (starts n))
    (def end (if (< (+ n 1) (length starts)) (first (starts (+ n 1))) (length lines)))
    (array/push out [name (+ i 1) (string/join (slice lines i end) "\n")]))
  out)

(defn- parse-list [text]
  (def rows @{})
  (each line (string/split "\n" text)
    (unless (or (empty? line) (string/has-prefix? "#" line))
      (def parts (filter |(not (empty? $)) (string/split " " line)))
      (when (>= (length parts) 3)
        (put rows (string (parts 1) " " (parts 2)) {:class (parts 0)}))))
  rows)

(defn main [& argv]
  (def check (has-value? argv "--check"))
  (os/cd tools/root)

  (def rows @[])
  (var total 0)
  (each path (tools/zig-files "src/zig")
    (def text (tools/strip-comments (slurp path)))
    (+= total (length (string/find-all ".?" text)))
    (each [name line body] (bodies-in text)
      (def unwrapped (receivers-unwrapped body))
      (def tested (receivers-tested body))
      (def accumulators (locals-initialised-null body))
      (each recv (sort (keys unwrapped))
        (when (get tested recv)
          (array/push rows
                      {:class (if (get accumulators recv) "accumulator" "tested")
                       :where (string path ":" line)
                       :recv recv
                       :n (unwrapped recv)
                       :fn name})))))

  (sort rows (fn [a b] (< (a :where) (b :where))))
  (def tested-rows (filter |(= ($ :class) "tested") rows))
  (var occurrences 0)
  (each r tested-rows (+= occurrences (r :n)))

  (def out @"")
  (buffer/push out "# `.?` whose null the same function also tests.\n")
  (buffer/push out "# Generated by `./tools/check/optionals.janet`; do not edit.\n#\n")
  (buffer/push out "# See that file's header for what the class means and what it cannot see.\n#\n")
  (buffer/push out "# **Class `tested` must be empty.**\n#\n")
  (buffer/push out (string/format "#   tested       %d sites, %d occurrences\n" (length tested-rows) occurrences))
  (buffer/push out (string/format "#   accumulator  %d sites\n" (- (length rows) (length tested-rows))))
  (buffer/push out (string/format "#   `.?` in src/zig  %d occurrences\n" total))
  (buffer/push out "#\n# columns: class  site  receiver  occurrences  function\n\n")
  (each r rows
    (buffer/push out (string/format "%-10s %-40s %-28s %-4d %s\n"
                                    (r :class) (r :where) (r :recv) (r :n) (r :fn))))
  (def text (string out))

  (if check
    (do
      (def old (parse-list (slurp list-path)))
      (def new (parse-list text))
      (def arrived (sort (filter |(nil? (get old $)) (keys new))))
      (def departed (sort (filter |(nil? (get new $)) (keys old))))
      (each k departed (print "retired  " k))
      (each k arrived (eprint "NEW      " k))
      (when (and (empty? arrived) (empty? departed))
        (print "the tree and " list-path " agree"))
      (print (length rows) " sites in class `tested` (" occurrences " occurrences)"
             (if (empty? rows) "" " -- the gate is that this is zero"))
      (os/exit (if (empty? rows) 0 1)))
    (do
      (spit list-path text)
      (print "wrote " list-path " -- " (length tested-rows) " sites in class `tested`, "
             occurrences " occurrences, out of " total " `.?` in src/zig")
      (os/exit 0))))
