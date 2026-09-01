#!/usr/bin/env janet
# Every definition in `src/zig` that carries `callconv(.c)`, classified by what
# reaches it that way.
#
#     ./tools/check/callconv.janet           regenerate tools/check/callconv.txt
#     ./tools/check/callconv.janet --check    fail if the tree disagrees with it
#
# ## Why this exists
#
# `DESIGN.md`'s D7 says a definition carries `callconv(.c)` only if `capi.zig`
# exports it, libc or the loader calls it back, or it fills an erased slot. That
# is a rule about *definitions*, and Phase 15 Part 5 met it **by reading**: a
# person went through the sites and reported them clean. A rule met by reading
# is a claim, and Phase 15's own hand-offs say twice what happens to those --
# `zig build test`'s 42 had never been compiled, and three cross-builds had
# never been run. So this asks the same question mechanically.
#
# ## What is and is not in the population
#
# Three shapes spell `callconv(.c)` and only one of them is a definition:
#
#   extern fn janet_x(...) callconv(.c) T;    a *declaration* of something
#                                             outside. `cabi.zig` and
#                                             `crossings.zig` own these and
#                                             `seam.janet` polices where they
#                                             may appear.
#   ?*const fn (...) callconv(.c) T           a function-pointer *type*. It is
#                                             what creates an erased slot
#                                             rather than what fills one, and
#                                             it is inventoried separately
#                                             below.
#   fn name(...) callconv(.c) T { ... }       a definition. **This is the
#                                             population.**
#
# ## The classes
#
#   export    the tree `@export`s it, or `capi.zig` names it in a `publish`
#             assertion. It is a published symbol and its calling convention is
#             the ABI.
#   slot      its address is stored in a struct field -- an `AbstractType`
#             vtable, a method row, a `Reg` row, a `Timeout`'s callback. The
#             slot's declared type is `callconv(.c)`, so the definition has no
#             choice.
#   callback  its address is passed as a call argument. libc, the loader or the
#             host calls it back: `pthread_create`, `atexit`, `signal`, an FFI
#             trampoline.
#   residue   nothing above. **This class must be empty** -- a `callconv(.c)`
#             nothing reaches by pointer is a translation artefact, and it
#             costs a real calling convention at every call for nothing.
#
# The classification is by **what takes the address**, which is decidable from
# the text, rather than by what the author meant. A definition whose address is
# taken twice lands in the first class that matches, in the order above.
#
# ## The comparison drops the line number
#
# A row is keyed by its **file and name**, not by `file:line`. A comment gaining
# a line above a declaration would otherwise retire one row and introduce
# another with the same class -- noise that has to be eyeballed every time, and
# noise is where a real change hides. `layouts.janet` learned this first and
# `optionals.janet` second; this is the same lesson, not a new one.
#
# ## What it cannot see
#
# An address taken through a `comptime` indirection -- `@field(S, name)` over a
# generated list -- reads as nothing taking it, and would score `residue`. The
# tree has none today; if one arrives, it belongs in this header as a named
# class rather than in an exemption list, for the reason `optionals.janet`'s
# header gives.

(import ../common :as tools)

(def list-path "tools/check/callconv.txt")

(defn- decl-before
  ``The `fn` that this `callconv(.c)` belongs to, as [kind name].

  `kind` is `:extern`, `:type` or `:def`. Walks back to the nearest `fn` token,
  which is the one this convention qualifies: a nested function-pointer
  *parameter* would put a closer one in the way, and the tree has none.``
  [text at]
  (var i (dec at))
  (var found nil)
  (while (and (>= i 1) (nil? found))
    (when (and (= (chr "f") (text i)) (= (chr "n") (text (+ i 1)))
               (or (= i 0) (not (tools/word-byte? (text (dec i)))))
               (not (tools/word-byte? (text (+ i 2)))))
      (set found i))
    (-- i))
  (unless found (break [:type nil]))
  # The name, if there is one: `fn foo(` has one, `*const fn (` does not.
  (var j (+ found 2))
  (while (and (< j (length text)) (= (chr " ") (text j))) (++ j))
  (var k j)
  (while (and (< k (length text)) (tools/word-byte? (text k))) (++ k))
  (def name (if (> k j) (string/slice text j k) nil))
  # `extern` within the declaration's own prefix -- the 24 bytes before `fn`,
  # which covers `pub extern fn` and `extern fn` and nothing further back.
  (def prefix (string/slice text (max 0 (- found 24)) found))
  (cond
    (string/find "extern" prefix) [:extern name]
    (nil? name) [:type nil]
    [:def name]))

(defn- sites [text]
  "Every `callconv(.c)` in `text`, as [kind name line]."
  (def out @[])
  (each i (string/find-all "callconv(.c)" text)
    (def [kind name] (decl-before text i))
    (def line (inc (length (string/find-all "\n" (string/slice text 0 i)))))
    (array/push out [kind name line]))
  out)

(defn main [& argv]
  (def check (has-value? argv "--check"))
  (os/cd tools/root)

  (def files (tools/zig-files "src/zig"))
  (def bodies @{})
  (each path files (put bodies path (tools/strip-comments (slurp path))))
  (def whole (string/join (values bodies) "\n"))
  (def exports (bodies "src/zig/capi.zig"))
  (def module (bodies "src/zig/module.zig"))

  (def defs @[])
  (var extern-decls 0)
  (var fn-types 0)
  (each path files
    (each [kind name line] (sites (bodies path))
      (case kind
        :extern (++ extern-decls)
        :type (++ fn-types)
        :def (array/push defs @{:name name :where (string (string/slice path 8) ":" line)}))))

  # The set of names whose address `capi.zig` or `module.zig` publishes. Both
  # spell the target through a container -- `@export(&Shim.modInit, ...)`,
  # `publish("janet_wrap_nil", &impl.value_helpers_wrap.abi.fromNil, ...)` --
  # so the last path segment is the definition and the prefix is how the file
  # reaches it.
  (def published @{})
  (each pattern ["@export(&" "publish(\"" ", &"]
    (var at 0)
    (while (def i (string/find pattern whole at))
      (set at (+ i (length pattern)))
      (var j at)
      (while (and (< j (length whole))
                  (or (tools/word-byte? (whole j)) (= (chr ".") (whole j))))
        (++ j))
      (def path (string/slice whole at j))
      (unless (empty? path)
        (def segments (string/split "." path))
        (put published (last segments) true))))

  (each d defs
    (def n (d :name))
    # Every place the tree takes this definition's address, classified by the
    # shape of the line that takes it. A field initialiser is an erased slot; a
    # bare call argument is a callback the host invokes.
    (var slot false)
    (var callback false)
    (each i (string/find-all n whole)
      (def after (get whole (+ i (length n)) 0))
      (def before (if (> i 0) (whole (dec i)) 0))
      # A mention is this name only if neither side continues an identifier or
      # a path. `(` after it is a *call*, which is not a reference to the
      # function's address and so is not a reason for a calling convention.
      (when (and (not (tools/word-byte? after))
                 (not (tools/word-byte? before))
                 (not= (chr "(") after))
        # Skip the declaration itself: `fn <n>` with the keyword before it.
        (def head (string/slice whole (max 0 (- i 20)) i))
        (unless (string/has-suffix? "fn " head)
          (def start (or (last (string/find-all "\n" (string/slice whole 0 i))) -1))
          (def line (string/trim (string/slice whole (inc start) (+ i (length n)))))
          (if (peg/match ~(* "." (some (+ :w "_")) (any " ") "=" (any " ") (? "&")
                            (any (+ :w "_" ".")) -1)
                         line)
            (set slot true)
            (set callback true)))))

    (put d :class
         (cond
           (get published n) "export"
           slot "slot"
           callback "callback"
           "residue")))

  (sort defs (fn [a b] (< (a :where) (b :where))))
  (def residue (filter |(= ($ :class) "residue") defs))
  (def counts @{})
  (each d defs (put counts (d :class) (+ 1 (get counts (d :class) 0))))

  (def out @"")
  (buffer/push out "# Definitions in `src/zig` carrying `callconv(.c)`, by what reaches them.\n")
  (buffer/push out "# Generated by `./tools/check/callconv.janet`; do not edit.\n#\n")
  (buffer/push out "# See that file's header for what each class means and what it cannot see.\n#\n")
  (buffer/push out "# **Class `residue` must be empty.**\n#\n")
  (each k ["export" "slot" "callback" "residue"]
    (buffer/push out (string/format "#   %-9s %d\n" k (get counts k 0))))
  (buffer/push out (string/format "#\n#   not definitions: %d `extern fn` declarations, %d function-pointer types\n"
                                  extern-decls fn-types))
  (buffer/push out "#\n# columns: class  site  function\n\n")
  (each d defs
    (buffer/push out (string/format "%-9s %-44s %s\n" (d :class) (d :where) (d :name))))
  (def text (string out))

  (if check
    (do
      (def old (string/split "\n" (slurp list-path)))
      (def new (string/split "\n" text))
      (defn rows [ls]
        (def m @{})
        (each l ls
          (unless (or (empty? l) (string/has-prefix? "#" l))
            (def p (filter |(not (empty? $)) (string/split " " l)))
            (when (>= (length p) 3)
              (put m (string (first (string/split ":" (p 1))) " " (p 2)) (p 0)))))
        m)
      (def o (rows old)) (def n (rows new))
      (each k (sort (filter |(nil? (get n $)) (keys o))) (print "retired  " k))
      (each k (sort (filter |(nil? (get o $)) (keys n))) (eprint "NEW      " k))
      (each k (sort (keys n))
        (when (and (get o k) (not= (o k) (n k)))
          (eprint "MOVED    " k ": " (o k) " -> " (n k))))
      (print (length defs) " definitions, " (length residue) " in class `residue`"
             (if (empty? residue) "" " -- the gate is that this is zero"))
      (os/exit (if (empty? residue) 0 1)))
    (do
      (spit list-path text)
      (print "wrote " list-path " -- " (length defs) " definitions, "
             (length residue) " in class `residue`")
      (os/exit 0))))
