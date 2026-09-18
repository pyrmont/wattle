#!/usr/bin/env janet
# Every identifier a comment in `src/` or `test/` names that the tree does not
# declare.
#
#     ./res/check/references.janet           regenerate res/check/references.txt
#     ./res/check/references.janet --check    fail if the tree disagrees with it
#
# ## Why this exists
#
# A comment describing the code beneath it does not drift: the thing it
# describes is the thing it sits on. A comment naming *another* declaration
# does, because nothing binds the name in the prose to the name in the code. A
# rename moves the declaration and leaves every mention of it behind, and no
# build, test or existing instrument says a word.
#
# Measured at Phase 17 Part 2b, over the comment lines of `src-files`: **239 of
# 262 camelCase identifiers named in comments resolved, and 24 of 305
# `janet_*` names did.** The Zig-native prose is accurate; the C-era prose is
# not. That is not a decay rate, it is one rename event -- C to Zig -- that was
# never propagated into the comments, so the backlog is bounded and this
# instrument is what stops a second one accumulating.
#
# Five camelCase rows were found by reading in that session and every one of
# them had survived a pass whose whole subject was the comments:
# `symbolDeinit` for `symbols.deinit`, `pointerBufferUnsafe` for
# `pointerUnsafe`, `registrySort` for `sortRows`, `cfunsExt` for `Installer`,
# and `raise.callCFunction` for `raise.cfunction`. Four were inherited and
# carried through a rewrite unchecked; reading is not what should find the
# sixth.
#
# ## What counts as resolved
#
# **The name is spelled somewhere in code** -- in `src/`, `test/`, `examples/`
# or `build.zig`, with comments and string literals stripped by
# `tools/strip-comments`. Deliberately loose about *how* the name is reached,
# and loose in the same direction as `orphans.janet`: a name is resolved if any
# file writes it. A loose test gives a small must-be-empty class and no false
# accusations, which is what makes each row worth reading.
#
# A literal is not code for this question, for `orphans.janet`'s reason. The
# case here was `janet_addtimeout` and `janet_addtimeout_nil`, named in a doc
# comment in `test/ev_loop.zig` and declared nowhere: the file's own
# contract-only docstring was the sole place either was written, so each
# resolved against the other half of its own mistake.
#
# It follows that this cannot see a *wrong* name that happens to exist
# elsewhere. `deinitBlock` would resolve whether or not the file citing it is
# the file that has it. This finds names for things that are not there at all,
# which is the population that a rename creates.
#
# ## What the population is, and what it is not
#
# **Two shapes are gated, and the reason is that both are this tree's own.**
#
#   - `camelCase` -- Zig's function convention and this runtime's. A camelCase
#     name in a comment is a claim about a declaration here.
#   - `janet_*` and `janetc_*` -- the C-era symbols, the second being the
#     compiler's own family. The runtime declares none of them except the
#     handful `capi.zig` still exports, so an unresolved one is a name for
#     something the tree used to have. `janetc_*` is `snake_case` and was
#     ungated with the rest of that shape until seven of them were found by
#     reading; the prefix is what separates them from the C fields and libc
#     functions a comment may legitimately name.
#
# **Everything else is deliberately not gated**, because a comment that names
# something outside this tree is doing its job. `SCREAMING_CASE` is C macros
# and libc constants under discussion (`JANET_RECURSION_GUARD`, `SIZE_MAX`,
# `EINTR`); `snake_case` is C functions and struct fields (`s_addr`, `_data`),
# less the `janetc_*` prefix gated above; `Capitalized` is a mix of C types
# being compared against (`JanetTable`) and this tree's own. Gating those
# three costs 393 rows of
# which almost all are legitimate, which is an instrument nobody reads --
# measured before this file was written, rather than assumed.
#
# The `Capitalized` shape is the one worth revisiting. It holds real findings
# (`KqueueWatcherState` names nothing) mixed with legitimate external ones
# (`StaticStringMap`, `VaList`), and separating them needs a rule this does not
# have. It is listed as `ungated` with its count so the next reader sees the
# size of what is not being checked.
#
# ## The classes
#
#   c-era      an unresolved `janet_*`. **A bounded backlog, not a gate**: it
#              is what Phase 17 Part 2 is working through, file by file, and
#              the count is the number left. It reaches zero when the prose
#              pass does.
#
# ## `test/` is in the population, and it is the larger half
#
# The prose pass's own population is `src/`, and this was scoped to match it
# until the counts were taken: **`test/` holds 328 rows to `src/`'s 262**, 314
# of them `janet_*` across 203 distinct names, with `harness.zig` and
# `ev_loop.zig` at twenty each. `harness.zig` is the worse kind, because it
# teaches the protected-scope API to every contract author in the tree using
# two names -- `janet_try_init` and `janet_restore` -- that the tree does not
# have, four lines above a `defer` that calls `signal_core.restore`.
#
# So the population is both. The site column carries the directory, and the
# header counts each separately so that finishing `src/` is still visible when
# `test/` has not started. `examples/` and `build.zig` stay out: they are a
# handful of files and neither is a place a reader learns the runtime from.
#   unresolved an unresolved camelCase name. Each row is a comment naming a
#              declaration that is not there. **The gate is that no row is
#              new**, and the class is a backlog that shrinks to zero as Part 2
#              reaches each file -- an empty class was not achievable the day
#              this was written and claiming it would have made the check a
#              formality.
#
# ## The comparison drops the line number
#
# A row is keyed by its file and name, for the reason `orphans.janet` and
# `layouts.janet` both give: a comment gaining a line above it would otherwise
# retire one row and introduce an identical one, and noise is where a real
# change hides.

(import ../common :as tools)

(def list-path "res/check/references.txt")

(defn- backticked
  ``Every identifier named inside backticks on a comment line of `text`, as
  [name line].

  A backticked span is split on `.`, so `raise.cfunction` offers both halves
  and a qualified name is checked at both ends -- which is what caught
  `raise.callCFunction`, whose left half was right. A trailing `()` is dropped.
  A component that is not a bare identifier -- `array/ensure`, `-Dnanbox`,
  `%v` -- is not one and is skipped.

  A span whose last component is a source suffix is a file name rather than a
  qualified declaration, and is skipped whole. `gc.zig` was harmless split,
  its left half being ungated anyway; `wattle_features.h` is not, its left half
  landing in the runtime's own population as a name for a header that exists.``
  [text]
  (def out @[])
  (def suffixes {"zig" true "h" true "c" true "janet" true "md" true
                 "txt" true "sh" true})
  (def lines (string/split "\n" text))
  (for i 0 (length lines)
    (def line (lines i))
    # A comment line, in any of Zig's three spellings.
    (when (peg/match ~(* (any " ") "//") line)
      (each span (or (peg/match ~(any (+ (* "`" (<- (some (if-not "`" 1))) "`") 1)) line) [])
        (def bare (if (string/has-suffix? "()" span)
                    (string/slice span 0 -3)
                    span))
        # A `std.`-qualified span names Zig's standard library, which this tree
        # does not declare and must not be accused of missing. The prefix is
        # the only reliable signal for that: `ceilPowerOfTwo` bare is
        # indistinguishable from one of ours.
        (def parts (string/split "." bare))
        (unless (or (string/has-prefix? "std." bare)
                    (suffixes (last parts)))
        (each part parts
          (when (peg/match ~(* (<- (* (+ :a "_") (any (+ :w "_")))) -1) part)
            (array/push out [part (inc i)])))))))
  out)

(defn- shape
  "Which gated population `name` belongs to, or nil for the ungated rest."
  [name]
  (cond
    (or (string/has-prefix? "janet_" name)
        (string/has-prefix? "janetc_" name)) "c-era"
    # camelCase: a lowercase run, then an uppercase, then anything.
    (peg/match ~(* (some (range "az" "09")) (range "AZ") (any (+ :w "_")) -1) name) "unresolved"
    nil))

(defn main [& argv]
  (def check (has-value? argv "--check"))
  (os/cd tools/root)

  # The code corpus: every Zig file in the repository with its comments and
  # its string literals stripped. A name inside a docstring, a registration
  # string or an `@import` path is prose or a path rather than a declaration,
  # so resolving against one says a name exists when nothing declares it.
  (def code @"")
  (each path (array/concat @[] (tools/src-files)
                           (tools/zig-files "test")
                           (tools/zig-files "examples")
                           @["build.zig"])
    (buffer/push code (tools/strip-comments (slurp path) false))
    (buffer/push code "\n"))
  (def corpus (string code))

  (defn declared? [name]
    (var at 0)
    (var found false)
    (var going true)
    (while going
      (def i (string/find name corpus at))
      (if (nil? i)
        (set going false)
        (do
          (def before (if (> i 0) (corpus (dec i)) 0))
          (def after (get corpus (+ i (length name)) 0))
          (when (and (not (tools/word-byte? before)) (not (tools/word-byte? after)))
            (set found true)
            (set going false))
          (set at (+ i (length name))))))
    found)

  (def resolved @{})
  (def rows @[])
  (var cited 0)
  (var ungated 0)
  (each path (array/concat @[] (tools/src-files) (tools/zig-files "test"))
    (each [name line] (backticked (slurp path))
      (++ cited)
      (def class (shape name))
      (if (nil? class)
        (++ ungated)
        (do
          (unless (has-key? resolved name) (put resolved name (declared? name)))
          (unless (resolved name)
            (array/push rows {:class class
                              :where (string (string/replace "src/" "" path) ":" line)
                              :name name}))))))

  # One row per file and name: a name cited five times in one file is one
  # finding and one edit.
  (def seen @{})
  (def unique @[])
  (each r rows
    (def key (string (first (string/split ":" (r :where))) " " (r :name)))
    (unless (has-key? seen key)
      (put seen key true)
      (array/push unique r)))
  (sort unique (fn [a b] (< (string (a :where) (a :name)) (string (b :where) (b :name)))))

  (def broken (filter |(= ($ :class) "unresolved") unique))
  (def c-era (filter |(= ($ :class) "c-era") unique))

  (def out @"")
  (buffer/push out "# Identifiers named in `src/` and `test/` comments that the tree does not declare.\n")
  (buffer/push out "# Generated by `./res/check/references.janet`; do not edit.\n#\n")
  (buffer/push out "# See that file's header for what counts as resolved, which shapes are\n")
  (buffer/push out "# gated, and why the other three are not.\n#\n")
  (buffer/push out "# **Class `unresolved` must be empty.** Class `c-era` is the bounded\n")
  (buffer/push out "# backlog Phase 17 Part 2 is working through; it reaches zero when the\n")
  (buffer/push out "# prose pass does.\n#\n")
  (defn area [r] (if (string/has-prefix? "test/" (r :where)) "test/" "src/"))
  (defn tally [rs a] (length (filter |(= (area $) a) rs)))
  (buffer/push out (string/format "#   c-era      %-5d  (src/ %d, test/ %d)\n"
                                  (length c-era) (tally c-era "src/") (tally c-era "test/")))
  (buffer/push out (string/format "#   unresolved %-5d  (src/ %d, test/ %d)\n"
                                  (length broken) (tally broken "src/") (tally broken "test/")))
  (buffer/push out (string/format "#\n#   %d identifiers cited in comments, %d of them in an ungated shape\n"
                                  cited ungated))
  (buffer/push out "#\n# columns: class  site  name\n\n")
  (each r unique
    (buffer/push out (string/format "%-11s %-44s %s\n" (r :class) (r :where) (r :name))))
  (def text (string out))

  (if check
    (do
      (defn parse [ls]
        (def m @{})
        (each l (string/split "\n" ls)
          (unless (or (empty? l) (string/has-prefix? "#" l))
            (def p (filter |(not (empty? $)) (string/split " " l)))
            (when (>= (length p) 3)
              (put m (string (first (string/split ":" (p 1))) " " (p 2)) (p 0)))))
        m)
      (def o (parse (slurp list-path))) (def n (parse text))
      (each k (sort (filter |(nil? (get n $)) (keys o))) (print "retired  " k))
      (each k (sort (filter |(nil? (get o $)) (keys n))) (eprint "NEW      " k))
      (def added (sort (filter |(nil? (get o $)) (keys n))))
      (print (length c-era) " `janet_*` names left, " (length broken)
             " unresolved camelCase"
             (if (empty? added) "" " -- the gate is that no row is NEW"))
      (os/exit (if (empty? added) 0 1)))
    (do
      (spit list-path text)
      (print "wrote " list-path " -- " (length broken) " unresolved, "
             (length c-era) " `janet_*` remaining, out of " cited " cited")
      (os/exit 0))))
