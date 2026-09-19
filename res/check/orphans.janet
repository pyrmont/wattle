#!/usr/bin/env janet
# Every `pub` declaration in the runtime source that nothing in the tree references.
#
#     ./res/check/orphans.janet           regenerate res/check/orphans.txt
#     ./res/check/orphans.janet --check    fail if the tree disagrees with it
#
# ## Why this exists
#
# `build.zig` refuses to build on a file-scope `const` its own file never uses.
# That check has a blind spot with a shape: **a `pub` declaration is invisible
# to it**, because `pub` says "another file may use this" and the build has no
# way to ask whether one does. So does a declaration inside a container, which
# is not file-scope at all.
#
# Two populations of exactly that shape were found in Phase 15 by *reading a
# plan that happened to name them* -- eighteen `pub const` left in
# `constants.zig` with no consumer after Part 3's enums, and five translate-c
# `pub fn data(_self: anytype)` accessors on the heads, dead since the heads
# were re-declared in Zig. `handoff-2.md` wrote down the rule that a third one
# is worth an instrument rather than a third reading. `ev.JanetOSMutex` was the
# third, and this is the instrument.
#
# ## What it counts as a reference
#
# The declared name, spelled anywhere in `src/`, `test/`, `examples/` or
# `build.zig` other than at its own declaration, in code rather than in a
# comment or a string literal. That is deliberately loose about *how* the name
# is reached: `@import` qualified, bare inside its own file, in an `@export`, in
# a `publish` assertion. A loose test gives a **small** must-be-empty class and
# no false accusations, which is what makes each row worth reading.
#
# A string literal is not code for this question. `pub const date =
# @import("runtime/os/date.zig")` names `date` twice on its own line, once as
# the declaration and once inside the path, so counting the literal made the
# whole of `root.zig`'s namespace block exempt itself. `debug.stacktrace` was
# the case that mattered: nothing calls it, and it read as referenced because
# `corefn.reg` registers `"debug/stacktrace"` beside it. Nothing in the tree
# is reached only through a literal -- an `@export(&f, ...)` names `f` in code
# on the same line -- so the strictness costs no row.
#
# ## The classes
#
#   surface   declared in `abi.zig`, `module.zig` or `capi.zig`. These three are
#             published to a separately compiled module or to a C caller by
#             symbol, so "nothing in this tree names it" is the expected state
#             rather than a finding. The burden on `abi.zig` falls on a reader
#             instead: its header lists the five kinds of
#             declaration the file may hold, and the file is read against that
#             list.
#   namespace `root.zig`'s `pub const <name> = @import(...)` block. That block
#             is the runtime's namespace, not a list of consumers: it is the
#             whole of what `test/` can reach a subsystem through, and it is
#             complete on purpose so that adding a contract does not also mean
#             editing the root. Decided by the declaration's shape in one named
#             file rather than by a list, so a *different* kind of unreferenced
#             `pub const` in `root.zig` is still a row.
#   orphan    everything else. **This class must be empty.**
#
# ## The comparison drops the line number
#
# A row is keyed by its **file and name**, not by `file:line`, for the reason
# `layouts.janet`'s `parse` gives: a comment gaining a line above a declaration
# would otherwise retire one row and introduce another with the same class, and
# noise is where a real change hides.
#
# ## What it cannot see
#
# A declaration reached only through `@field(S, comptime_name)` where the name
# is computed scores as an orphan. There is none in the tree today. Neither is
# a declaration *used*, only *named*: a `pub const` mentioned once in dead code
# reads as referenced. That is the same looseness as above and it errs the same
# way -- towards silence rather than towards a row nobody can act on.

(import ../common :as tools)

(def list-path "res/check/orphans.txt")

(def surface-files
  ``The three files whose `pub` declarations are published rather than called.

  `abi.zig` is the module an author's package gets, `module.zig` is the author
  surface itself and `capi.zig` is the export manifest. A declaration in one of
  them exists to be reached from outside this tree, so the reference test here
  cannot see its consumer and must not accuse it.``
  {"src/api/abi.zig" true "src/module.zig" true "src/runtime/capi.zig" true})

(defn- declarations [text path]
  ``Every `pub const`, `pub fn`, `pub var` and `pub inline fn` in `text`, as
  [name line]. Both file-scope and inside a container: the indent is not read,
  because a `pub` inside a `struct` is exactly the population `build.zig`
  cannot see.``
  (def out @[])
  (def lines (string/split "\n" text))
  (for i 0 (length lines)
    (def m (peg/match ~(* (any " ")
                          "pub " (? (+ "inline " "noinline " "export " "extern "))
                          (+ "const " "fn " "var " "threadlocal var ")
                          (<- (some (+ :w "_"))))
                      (lines i)))
    (when m (array/push out [(first m) (inc i)])))
  out)

(defn main [& argv]
  (def check (has-value? argv "--check"))
  (os/cd tools/root)

  (def sources @{})
  (each path (array/concat @[] (tools/src-files)
                           (tools/zig-files "test")
                           (tools/zig-files "examples")
                           @["build.zig"])
    # `keep-literals` false: a name inside a docstring, a registration string
    # or an `@import` path is prose or a path rather than a use of the
    # declaration, and counting one hides a dead declaration behind its own
    # mention.
    (put sources path (tools/strip-comments (slurp path) false)))

  (def rows @[])
  (var total 0)
  (each path (tools/src-files)
    (each [name line] (declarations (sources path) path)
      (++ total)
      # A reference is the name spelled somewhere other than at its own
      # declaration. Count occurrences tree-wide and subtract the one the
      # declaration itself contributes.
      (var uses 0)
      (eachp [_ body] sources
        (var at 0)
        (while (def i (string/find name body at))
          (def before (if (> i 0) (body (dec i)) 0))
          (def after (get body (+ i (length name)) 0))
          (unless (or (tools/word-byte? before) (tools/word-byte? after))
            (++ uses))
          (set at (+ i (length name)))))
      (when (<= uses 1)
        (def namespace
          (and (= path "src/root.zig")
               (peg/match ~(* (any " ") "pub const " (some (+ :w "_")) " = @import(")
                          ((string/split "\n" (sources path)) (dec line)))))
        (array/push rows {:class (cond (surface-files path) "surface"
                                       namespace "namespace"
                                       "orphan")
                          :where (string (string/replace "src/" "" path) ":" line)
                          :name name}))))

  (sort rows (fn [a b] (< (a :where) (b :where))))
  (def orphans (filter |(= ($ :class) "orphan") rows))

  (def out @"")
  (buffer/push out "# `pub` declarations in `src/` that nothing in the tree references.\n")
  (buffer/push out "# Generated by `./res/check/orphans.janet`; do not edit.\n#\n")
  (buffer/push out "# See that file's header for what counts as a reference and what the\n")
  (buffer/push out "# classes mean.\n#\n")
  (buffer/push out "# **Class `orphan` must be empty.**\n#\n")
  (def counts @{})
  (each r rows (put counts (r :class) (+ 1 (get counts (r :class) 0))))
  (each k ["surface" "namespace" "orphan"]
    (buffer/push out (string/format "#   %-9s %d\n" k (get counts k 0))))
  (buffer/push out (string/format "#\n#   %d `pub` declarations in src/\n" total))
  (buffer/push out "#\n# columns: class  site  name\n\n")
  (each r rows
    (buffer/push out (string/format "%-9s %-44s %s\n" (r :class) (r :where) (r :name))))
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
      (print (length rows) " unreferenced `pub` declarations, " (length orphans)
             " in class `orphan`"
             (if (empty? orphans) "" " -- the gate is that this is zero"))
      (os/exit (if (empty? orphans) 0 1)))
    (do
      (spit list-path text)
      (print "wrote " list-path " -- " (length orphans) " in class `orphan`, out of "
             total " `pub` declarations")
      (os/exit 0))))
