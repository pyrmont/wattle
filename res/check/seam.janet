#!/usr/bin/env janet
# Enumerate the internal C-ABI seam: every `c.janet_*` name the tree spells,
# and what each one actually resolves to.
#
# What this counts is the runtime calling its own Zig code through the C ABI:
# `c.janet_table_get(...)` reaching a `janet_table_get` that is an `export fn`
# in `src/runtime/value/tables.zig`, by way of a declaration nothing checks against
# the definition. Such a call cannot carry an error union and cannot inline.
# Retiring one is pure liability paid down; there is no design decision in it.
#
# This tool produces the list to work from, and `--check` measures against the
# list checked in beside it.
#
# ## Why this is not a grep
#
# `phase_12.md` opened the item with
#
#     grep -rho 'c\.janet_[A-Za-z0-9_]*' src --include='*.zig'
#
# which reports 3,440 references across 269 names. Both numbers are wrong, in
# both directions, and neither error is visible in the output.
#
# **It counts prose.** Five of the 269 names occur only inside comments, and
# three of those name abis that no longer exist -- `janet_run_vm` and
# `janet_formatc` were retired in Phase 10, and `janet_` is a wildcard in a
# sentence (`c.janet_*_head`). A grep cannot tell a call from a comment about a
# call that used to be there, so the older a tree gets the more the count
# drifts. Comments are stripped here, with string literals respected.
#
# **It looked in half the tree.** `test/` holds *more* references than
# the runtime source does -- 5,018 against 3,430 -- because a Zig contract is
# compiled
# into a second copy of the runtime and reaches its subject the same way the
# runtime does. 85 names appear there and nowhere in `src/`. This is Phase
# 12's rule 1 for the second time in two increments: a population is measured
# over where you looked, so the sweep is written down beside the count.
#
# ## The three publication mechanisms, and why one grep cannot see them
#
# A `c.janet_x` reference resolves to a Zig definition three ways:
#
#     export fn janet_x(...) callconv(.c) T { ... }
#     comptime { @export(&xImpl, .{ .name = "janet_x" }); }
#     pub export const janet_x_type: abstract_type.AbstractType = .{ ... };
#
# An `export fn` sweep alone scores 261 of the 331 and reports the other 70 as
# external. Phase 11's rule 49 is the same shape from the other side -- a `pub
# extern` re-export made 29 call sites look like ordinary imports of a
# neighbour -- and the lesson is the same one: **the mechanism a symbol is
# published by is not visible at the call site.**
#
# ## What was not the seam, and the column that said so
#
# Two things went with `janet.h` at Phase 12 increment 5f, and both were
# already empty when they went.
#
# The `macro` mechanism was the remainder: translate-c rendered
# `#define janet_tuple_length(t) (janet_tuple_head(t)->length)` as ordinary Zig
# that inlines, so those call sites cost nothing and were never this item. They
# were listed anyway, because a complete accounting is what made the list
# checkable -- every name the tree spelled was either a symbol Zig publishes or
# a macro the header defined, and a name that was neither was a finding.
# Increment 5e expanded all eighteen at their 745 call sites, and the count has
# read `0 macro` since.
#
# The `header` column named the header that declared each name, and it was item
# 3's line: a name `janet.h` declared could not leave the export surface while
# the header shipped, and one only an internal header declared could go the
# moment its last caller did. 300 of the original 331 were `janet.h`'s. That
# question is answered -- the header is retired -- so the column has nothing
# left to say and there is nothing left to read it out of.
#
# What survives is the remaining mechanism: every name in the list is a symbol
# Zig publishes, three ways, and a name that resolves to none of them is a
# finding. `--check` still exits non-zero for one.
#
# ## Usage
#
#     ./res/check/seam.janet            regenerate res/check/seam.txt, print the summary
#     ./res/check/seam.janet --check    compare the tree against res/check/seam.txt
#     ./res/check/seam.janet --quiet    the summary only
#
# `--check` is a ratchet rather than a diff. Names leaving the list is the
# work; names *arriving* is a new C-ABI call written where a direct one would
# do, and that is what it exits non-zero for -- along with a name that resolves
# to no Zig export at all. A name that only changes its reference
# count is reported and not failed. Verified capable of failing on all three.

(import ../common :as tools)

(def list-path "res/check/seam.txt")

### Reading Zig without reading its comments

# `strip-comments` and `zig-files` moved to `tools.janet` at Phase 12
# increment 5d, on rule 26: the stripper belongs in a library rather than in
# the one tool that learned it, so that the next tool reaches for it instead
# of re-deriving it. `convert.janet` is that next tool.

### The three publication mechanisms

(def- word ~(choice :w "_"))

(def- export-fn-peg
  (peg/compile ~(any (choice (sequence (not (look -1 ,word))
                                       "export" :s+ "fn" :s+
                                       (capture (some ,word)))
                             1))))

# Two spellings of one mechanism. `capi.zig` states a direct export's signature
# in the same call that performs it -- `publish("sym", &target, fn ...)` -- so
# the symbol is the *first* argument there and the pointer follows it, where a
# bare `@export` has them the other way round. Recognising only the bare form
# left 88 names unresolved the first time the manifest changed shape, which is
# `res/README.md`'s warning arriving on schedule.
(def- export-at-peg
  (peg/compile ~(any (choice (sequence "@export(" (thru ".name") :s* "=" :s* "\""
                                       (capture (some ,word)) "\"")
                             (sequence "publish" (any "Hidden") "(\""
                                       (capture (some ,word)) "\"" :s* "," :s* "&")
                             1))))

(def- export-data-peg
  (peg/compile ~(any (choice (sequence (not (look -1 ,word))
                                       "export" :s+ (choice "const" "var") :s+
                                       (capture (some ,word)))
                             1))))

(def mechanisms
  [["export fn" export-fn-peg]
   ["@export" export-at-peg]
   ["export data" export-data-peg]])

(defn published
  "Every symbol `sources` publishes, as name -> [{:mech :path :line} ...].

  `sources` is path -> comment-stripped text. All three constructions are
  single-line in this tree -- verified, and a wrapped one would show up as an
  unresolved reference rather than as silence -- so the scan is by line, which
  is what makes it linear and what gives the line number for free.

  Every site is kept, because a name may be published from more than one --
  `dynlib.zig` gives `error_clib` two mutually exclusive comptime arms -- and
  the list says how many rather than picking one silently."
  [sources]
  (def out @{})
  (each path (sort (keys sources))
    (var line 0)
    (each text (string/split "\n" (sources path))
      (++ line)
      (each [mech pat] mechanisms
        (each name (or (peg/match pat text) [])
          (unless (get out name) (put out name @[]))
          (array/push (get out name) {:mech mech :path path :line line})))))
  out)

### Through the boundary

# Increment 5h batch A moved every `@export` into `src/runtime/capi.zig`, and this
# tool started answering `src/runtime/capi.zig` for all 86 names -- true, and
# useless, because the column exists to say *where the behaviour lives*. It
# went unnoticed for three batches: `--check` ratchets on a new name, so a
# definition that quietly became the same file for everything is not something
# it can see. Rule 70, and the reason this step exists.
#
# `capi.zig` publishes a name two ways, and both are resolvable:
#
#     @export(&impl.value_tables.get, .{ .name = "janet_table_get" });
#     pub fn janet_table_get(...) callconv(.c) T { return impl.value_tables.get(...); }
#
# The first names its target outright. The second names a local wrapper whose
# body is one `return impl.<alias>.<name>(` line -- the shape `capi.janet`
# generates and `capi-sync.janet` maintains. Either way the alias resolves
# through `capi.zig`'s own `impl` block, which is declarative, rather than by
# guessing that an underscore was a directory separator.

(def capi-path "src/runtime/capi.zig")

(defn- impl-aliases
  "`capi.zig`'s `impl` block: alias -> the path it imports."
  [text]
  (def out @{})
  (def pat (peg/compile ~(sequence (any :s) "pub const " (capture (some (choice :w "_")))
                                   " = @import(\"" (capture (to "\"")) "\"")))
  (var inside false)
  (each line (string/split "\n" text)
    (cond
      (string/has-prefix? "const impl = struct" line) (set inside true)
      (and inside (string/has-prefix? "};" line)) (set inside false)
      (when inside
        (when-let [m (peg/match pat line)]
          (put out (m 0) (string "src/runtime/" (m 1)))))))
  out)

(def- capi-target-peg
  (peg/compile ~(choice
                  (sequence (any :s) "@export(&" (capture (some (choice :w "_" "."))) ",")
                  (sequence (any :s) "publish" (any "Hidden") "(\"" (some (choice :w "_")) "\""
                            :s* "," :s* "&" (capture (some (choice :w "_" "." "(" ")")))
                            (choice "," ")")))))

(def- capi-call-peg
  (peg/compile ~(sequence (any :s) "return impl." (capture (some (choice :w "_")))
                          "." (capture (some (choice :w "_"))) "(")))

(defn- definition-lines
  "Every line `name` is defined on in `text`, each with its indentation."
  [text name]
  (def pat (peg/compile ~(sequence (any (sequence (choice "pub" "inline" "export" "extern") :s+))
                                   (choice "fn" "const" "var") :s+ ,name
                                   (choice "(" ":" " "))))
  (def out @[])
  (var line 0)
  (each l (string/split "\n" text)
    (++ line)
    (when (peg/match pat (string/trim l))
      (array/push out {:line line :top (= l (string/trim l))})))
  out)

(defn- definition-line
  "The one line `name` is defined on in `text`, or nil if it is not unique.

  Uniqueness is the test rather than first-match because an `@export` target
  may be a dotted path -- `impl.args.GetBuffer.abi`, or
  `impl.value_helpers_wrap.abi.fromNil` -- and the segment to resolve is
  whichever one names a definition. `abi` is the conventional member name for
  a C-ABI shim and so appears dozens of times in a file; requiring exactly one
  match is what makes it fall through to `GetBuffer` without a special case
  for the word.

  A definition at column zero wins over a nested one, which is what separates
  `wrap.zig`'s two `toFunction`s: the file's own, and the one inside the
  namespace that shadows it for a caller that asked for it."
  [text name]
  (def hits (definition-lines text name))
  (def top (filter (fn [h] (h :top)) hits))
  (cond
    (= 1 (length top)) ((first top) :line)
    (= 1 (length hits)) ((first hits) :line)
    nil))

(defn resolve-boundary
  "Repoint a `capi.zig` publication at the file whose definition it wraps.

  Returns the site unchanged when the chain cannot be followed. Two things
  land there. A hand-written spread wrapper -- `janet_unmarshal`, whose body is
  not one delegating call -- stays `capi.zig` because that genuinely is where
  its body is. And a target whose name is defined twice in the file it resolves
  to, as `toFunction` is in `wrap.zig`, stays rather than picking one: the
  column is a pointer for a reader, and a wrong pointer is worse than the
  boundary."
  [site sources]
  (if (not= (site :path) capi-path) site
    (let [text (get sources capi-path)
          lines (string/split "\n" text)
          aliases (impl-aliases text)
          at (get lines (- (site :line) 1) "")
          target (first (or (peg/match capi-target-peg at) []))]
      (if (nil? target) site
        (let [[alias segments]
              (if (string/has-prefix? "impl." target)
                (let [parts (string/split "." (string/slice target 5))]
                  [(first parts) (drop 1 parts)])
                (let [wl (definition-line text target)]
                  (if (nil? wl) [nil nil]
                    (let [body (get lines wl "")
                          m (peg/match capi-call-peg body)]
                      (if m [(m 0) [(m 1)]] [nil nil])))))]
          (if (nil? alias) site
            (let [path (get aliases alias)]
              (if (or (nil? path) (nil? (get sources path))) site
                # Try the dotted segments from the last inwards, and take the
                # first that names exactly one definition in the file.
                (let [text2 (get sources path)
                      dl (find-index identity
                                     (map (fn [n] (definition-line text2 n)) (reverse segments)))]
                  (if (nil? dl) site
                    {:mech (site :mech) :path path
                     :line ((map (fn [n] (definition-line text2 n)) (reverse segments)) dl)}))))))))))

### The references

# `janet` and not `janet_`, because the compiler's own abis are `janetc_*` --
# `janetc_emit_sss`, `janetc_regalloc_touch`, `janetc_shadowcheck`. Every one
# is an `export fn` reached through the C ABI, which is exactly what this tool
# enumerates, and the first version of it matched `janet_` and so left 37
# names and 347 references out of the list. Phase 12's rule 17: a population
# named by a prefix is a population measured over the prefix.
(def- ref-peg
  (peg/compile ~(any (choice (sequence (not (look -1 ,word))
                                       "c." (capture (sequence "janet" (some ,word))))
                             1))))

(defn references
  "Every `c.janet*` reference in `sources`, as name -> {path -> count}."
  [sources]
  (def out @{})
  (eachp [path text] sources
    (each name (or (peg/match ref-peg text) [])
      (unless (get out name) (put out name @{}))
      (def per (get out name))
      (put per path (+ 1 (get per path 0)))))
  out)

### The headers

# `strip-c-comments`, `macros` and `declares` stood here.  They read the C
# headers -- the macro table for the `macro` mechanism, and the declaring
# header for the `header` column -- and Phase 12 increment 5f deleted every one
# of those headers.  Rule 15: a check that depends on the thing being removed
# has to be spent before it, and both halves were already answering nothing.

### The list

(defn- render
  [rows counts]
  (def out @"")
  (buffer/push out
    "# The internal C-ABI seam.  Generated by `./res/check/seam.janet`; do not edit.\n"
    "#\n"
    "# Every `c.janet_*` name spelled in Zig code under `src/` and `test/`,\n"
    "# with what it resolves to.  Comments are stripped before counting, because\n"
    "# a comment about an abi retired two phases ago reads as a call.\n"
    "#\n"
    "# `export fn`, `@export` and `export data` are the three mechanisms Zig\n"
    "# publishes a symbol by, and every row is one of them: the runtime calling\n"
    "# its own Zig through the C ABI, which cannot carry an error union and\n"
    "# cannot inline.  A name that resolves to none of the three is a finding.\n"
    "#\n"
    "# The `macro` mechanism and the `header` column went with `janet.h` at\n"
    "# increment 5f; `seam.janet` records what they were for.\n"
    "#\n")
  (buffer/push out (string/format "# names          %5d  across %5d references\n"
                                  (counts :names) (counts :refs)))
  (buffer/push out "#\n")
  (buffer/push out (string/format "# references     %5d  in src/\n" (counts :src-refs)))
  (buffer/push out (string/format "#                %5d  in test/\n" (counts :test-refs)))
  (buffer/push out
    "#\n"
    "# columns: refs  src/    test/  mechanism  name  definition\n"
    "\n")
  (each row rows
    (buffer/push out (string/format "%5d %5d %5d  %-11s %-40s %s\n"
                                    (row :refs) (row :src) (row :test)
                                    (row :mech) (row :name) (row :where))))
  (string out))

(defn- parse-list
  "The names in a rendered list, as name -> row."
  [text]
  (def out @{})
  (each line (string/split "\n" text)
    (unless (or (empty? (string/trim line)) (string/has-prefix? "#" line))
      (def fields (filter |(not (empty? $)) (string/split " " (string/trim line))))
      (when (>= (length fields) 6)
        # refs src test mech name where -- `mech` may hold a space, and `where`
        # a ` +N`, so both ends are read inwards rather than by index.
        (def refs (scan-number (fields 0)))
        (def where-len (if (string/has-prefix? "+" (last fields)) 2 1))
        (def name (get fields (- (length fields) where-len 1)))
        (put out name {:refs refs :where (get fields (- (length fields) where-len))}))))
  out)

(defn main [& argv]
  (def check (has-value? argv "--check"))
  (def quiet (has-value? argv "--quiet"))
  (os/cd tools/root)

  (def paths (array/concat (tools/src-files) (tools/zig-files "test")))
  (def sources @{})
  (each path paths (put sources path (tools/strip-comments (slurp path))))

  # ## The declarations that were not in the declared place
  #
  # Part 8 increment 8a. Everything above measures `c.janet_*` -- a reference
  # through the `cabi` module. A file may instead write its own
  # `extern fn janet_x(...)` and call it unprefixed, which is the same promise
  # to the same linker and is invisible to every count in this file. There were
  # 77 of those, across 57 symbols and 30 files, serving 104 call sites that
  # this tool has never seen; three of them declared
  # `janet_table_get_keyword`'s sentinel away. 8a took the population to zero.
  #
  # **`cabi.zig` is the only file left, and the exemption is now a rule about
  # one file rather than a list of four.** The module table retired the symbol
  # boundary: a native module reaches the runtime through `src/api/interface.zig`'s
  # struct of function pointers, which the compiler type-checks at
  # `capi.zig`'s initializer, so `crossings.zig` and `cabi_check.zig` are gone
  # and neither `capi.zig` nor `module.zig` declares an `extern fn` any more.
  # What `cabi.zig` declares is libc's, which is genuinely outside this tree.
  # A `janet`-prefixed `extern fn` anywhere is now a finding, `cabi.zig`
  # included -- the runtime publishes no such name for one to resolve to.
  (def declared-elsewhere @[])
  (eachp [path text] sources
    (unless (string/has-prefix? "test/" path)
      (each i (string/find-all "extern fn janet" text)
        (array/push declared-elsewhere
                    [path (+ 1 (length (string/find-all "\n" (string/slice text 0 i))))]))))

  (def pubs-raw (published sources))
  # Every `@export` lives in `capi.zig` since increment 5h; follow each one
  # through to the definition it publishes. See `resolve-boundary`.
  (def pubs (tabseq [[name sites] :pairs pubs-raw]
              name (map (fn [s] (resolve-boundary s sources)) sites)))
  (def refs (references sources))

  # A name with more than one publication site gets an arbitrary one in the
  # `definition` column, so the column says how many there are.  This is not a
  # defect: `dynlib.zig` publishes `error_clib` twice from mutually exclusive
  # comptime arms, which is `util.h`'s arrangement rather than a choice.  A
  # genuine duplicate would fail the link, so it is not this tool's to catch.
  (defn where [site n]
    (string (site :path) ":" (site :line) (if (> n 1) (string " +" (- n 1)) "")))

  (def rows @[])
  (def unresolved @[])
  (each name (sort (keys refs))
    (def per (refs name))
    (var src 0)
    (var tst 0)
    (eachp [path n] per
      (if (string/has-prefix? "test/" path) (+= tst n) (+= src n)))
    (def sites (get pubs name))
    (if sites
      (array/push rows {:name name :refs (+ src tst) :src src :test tst
                        :mech ((first sites) :mech)
                        :where (where (first sites) (length sites))})
      (do
        (array/push unresolved name)
        (array/push rows {:name name :refs (+ src tst) :src src :test tst
                          :mech "UNRESOLVED" :where "-"}))))

  (defn total [rs key] (reduce (fn [a r] (+ a (r key))) 0 rs))
  (def counts
    {:names (length rows) :refs (total rows :refs)
     :src-refs (total rows :src) :test-refs (total rows :test)})

  # Sorted by weight, because the list is a work queue: the heaviest name is
  # the one whose retirement removes the most call sites.  The name breaks the
  # tie, so the file is a function of the tree rather than of the sort.
  (def ordered (sort (array/slice rows)
                     (fn [a b] (if (= (a :refs) (b :refs))
                                 (< (a :name) (b :name))
                                 (> (a :refs) (b :refs))))))
  (def text (render ordered counts))

  (unless quiet
    (print (counts :names) " names")
    (print (counts :refs) " references ("
           (counts :src-refs) " in src/, " (counts :test-refs) " in test/)"))

  (each name unresolved
    (eprint "unresolved: c." name " reaches no Zig export"))

  (each [path line] declared-elsewhere
    (eprint "a Janet symbol declared by hand: " path ":" line
            " -- the runtime publishes no `janet*` name to resolve it"))

  (if check
    (do
      (def old (parse-list (slurp list-path)))
      (def new (parse-list text))
      (def arrived (sort (filter |(nil? (get old $)) (keys new))))
      (def departed (sort (filter |(nil? (get new $)) (keys old))))
      (def moved (sort (filter |(and (get old $)
                                     (not= ((old $) :refs) ((new $) :refs)))
                               (keys new))))
      (each name departed
        (print "retired  " name " (was " ((old name) :refs) " references)"))
      (each name moved
        (print "changed  " name "  " ((old name) :refs) " -> " ((new name) :refs)))
      (each name arrived
        (eprint "NEW      " name "  " ((new name) :refs) " references, "
                ((new name) :where)))
      (when (and (empty? arrived) (empty? departed) (empty? moved))
        (print "the tree and " list-path " agree"))
      (when (empty? declared-elsewhere)
        (print "0 `extern fn janet*` under src/"))
      (os/exit (if (and (empty? arrived) (empty? unresolved)
                        (empty? declared-elsewhere)) 0 1)))
    (do
      (spit list-path text)
      (unless quiet (print "wrote " list-path))
      (os/exit (if (and (empty? unresolved) (empty? declared-elsewhere)) 0 1)))))
