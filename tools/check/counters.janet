#!/usr/bin/env janet
# Enumerate the signed loop counters that index a container, and what each one
# is signed *for*.
#
# The shape is
#
#     var i: i32 = 0;
#     while (i < BOUND) : (i += 1) { ... X[@intCast(i)] ... }
#
# and the question at each one is whether `i32` is the type of the quantity or
# residue from a field that used to be `i32`. Phase 14 Part 2 calls the second
# kind class (e), and the phase's gate is that class (e) is empty.
#
# This produces the list to work from, and `--check` measures against the list
# checked in beside it.
#
# ## Why this is an instrument and not a habit
#
# **Zig will not catch a signedness mistake here, in three separate ways, and
# all three were hit while writing this.**
#
#   * *Mixed-signedness comparison compiles.* `while (i32 < usize)` is not an
#     error, so converting a container's count field leaves every loop over it
#     silently mixed and there is no error list to work down. Every other
#     increment in Part 2 was driven by the compiler naming its own sites; this
#     population cannot be.
#
#   * *`for (0..x)` accepts an `i32` bound.* Converting a loop over
#     `fiber.capacity` -- one of the two populations Part 2 measured and
#     deliberately kept signed -- compiled clean, and only a reading caught it.
#
#   * *`@intCast` on a same-width value is a legal no-op.* A cast left behind
#     after its reason is gone never complains.
#
# So the classification cannot live in a script that is "right by
# construction"; that is a decision nobody can see and nobody can falsify. It
# lives here, as rows someone can disagree with, next to a check that fails
# when the tree and the rows drift apart.
#
# ## The classes
#
# A counter is legitimately signed when **the quantity can be negative in a
# correct execution**, or **its width is a recorded decision**, or **it crosses
# a seam and the cast sits at the seam**. Anything else is class (e).
#
#   c-decision  the bound is a field the port measured and kept `i32`: the four
#               flexible-array heads, and `JanetFiber`'s frame fields. Recorded
#               in `port/phase_14/part_02.md` under 2e.
#   c-signed    the quantity is genuinely signed -- a bytecode label, whose
#               jumps are `label - here`; an offset that is negated to mark
#               untrusted input.
#   b-seam      the bound crosses a serialization or host boundary and the
#               conversion sits at that boundary.
#   a-janet     the bound is a Janet integer, signed because Janet's are.
#   e           residue. **This class must be empty.**
#
# ## What this does not see
#
#     ./tools/check/counters.janet           regenerate tools/check/counters.txt
#     ./tools/check/counters.janet --check   fail if the tree disagrees with it
#
# Only the `var/while/+= 1` shape above. A counter that starts at one, steps by
# two, or walks backwards is a different shape and is not in this inventory;
# `part_02.md` records that limit rather than leaving it to be discovered.

(import ../common :as tools)

(def list-path "tools/check/counters.txt")

# The two populations Part 2 measured and kept `i32`. A bound naming one of
# these is class (c) by a recorded decision, not by inspection.
(def kept-signed
  ["tupleHead" "stringHead" "structHead" "abstractHead"
   ".frame" ".stackstart" ".stacktop" ".maxstack"])

(defn- resolve-bound [text before bound]
  ``The bound as written, or -- when it is a bare local -- the initialiser of
  its nearest preceding declaration. One level only: a chain wants a human, and
  saying so is better than guessing.``
  (if-not (peg/match ~(* (some (+ :w "_")) -1) bound)
    bound
    (do
      (var seen nil)
      (each pat [(string "var " bound " = ") (string "const " bound " = ")
                 (string "var " bound ": ") (string "const " bound ": ")]
        (each i (string/find-all pat (string/slice text 0 before))
          (def eol (or (string/find "\n" text i) (length text)))
          (set seen (string/slice text (+ i (length pat)) eol))))
      (or seen bound))))

(defn- classify-bound [bound]
  (cond
    (some |(string/find $ bound) kept-signed) "c-decision"
    (string/find "readNat" bound) "b-seam"
    (or (string/find "toInteger" bound) (string/find "getInteger" bound)) "a-janet"
    "e"))

(defn- loops-in [text]
  "Every `var N: i32 = 0;` immediately followed by `while (N < B) : (N += 1)`."
  (def found @[])
  (var at 0)
  (while true
    (def i (string/find "var " text at))
    (unless i (break))
    (set at (+ i 4))
    (def eol (or (string/find "\n" text i) (length text)))
    (def decl (string/trim (string/slice text i eol)))
    (def m (peg/match ~(* "var " (<- (some (+ :w "_"))) ": i32 = 0;" -1) decl))
    (when m
      (def name (first m))
      (def next-eol (or (string/find "\n" text (+ eol 1)) (length text)))
      (def nxt (string/trim (string/slice text (+ eol 1) next-eol)))
      (def w (peg/match ~(* "while (" ,name " < " (<- (to ")")) ") : (" ,name " += 1)") nxt))
      (when w
        (array/push found
                    {:name name
                     :bound (string/trim (first w))
                     :at i
                     :line (+ 1 (length (string/find-all "\n" (string/slice text 0 i))))}))))
  found)

(defn- parse-list [text]
  (def rows @{})
  (each line (string/split "\n" text)
    (unless (or (empty? line) (string/has-prefix? "#" line))
      (def parts (filter |(not (empty? $)) (string/split " " line)))
      (when (>= (length parts) 4)
        (put rows (string (parts 1) " " (parts 2)) {:class (parts 0) :bound (parts 3)}))))
  rows)

(defn main [& argv]
  (def check (has-value? argv "--check"))
  (os/cd tools/root)

  (def rows @[])
  (each path (tools/zig-files "src/zig")
    (def text (tools/strip-comments (slurp path)))
    (each l (loops-in text)
      (def resolved (resolve-bound text (l :at) (l :bound)))
      (array/push rows
                  {:class (classify-bound resolved)
                   :where (string path ":" (l :line))
                   :name (l :name)
                   :bound (l :bound)})))

  (sort rows (fn [a b] (< (a :where) (b :where))))
  (def by-class @{})
  (each r rows (put by-class (r :class) (+ 1 (get by-class (r :class) 0))))

  (def out @"")
  (buffer/push out "# Signed loop counters that index a container, and what each is signed for.\n")
  (buffer/push out "# Generated by `./tools/check/counters.janet`; do not edit.\n#\n")
  (buffer/push out "# See that file's header for the classes and for the three ways Zig does\n")
  (buffer/push out "# not catch a signedness mistake here.\n#\n")
  (buffer/push out "# **Class `e` must be empty.**\n#\n")
  (each k (sort (keys by-class))
    (buffer/push out (string/format "#   %-12s %d\n" k (by-class k))))
  (buffer/push out "#\n# columns: class  site  counter  bound\n\n")
  (each r rows
    (buffer/push out (string/format "%-12s %-40s %-16s %s\n"
                                    (r :class) (r :where) (r :name) (r :bound))))
  (def text (string out))

  (def residue (filter |(= ($ :class) "e") rows))
  (if check
    (do
      (def old (parse-list (slurp list-path)))
      (def new (parse-list text))
      (def arrived (sort (filter |(nil? (get old $)) (keys new))))
      (def departed (sort (filter |(nil? (get new $)) (keys old))))
      (each k departed (print "retired  " k))
      (each k arrived (eprint "NEW      " k "  " ((new k) :class)))
      (when (and (empty? arrived) (empty? departed))
        (print "the tree and " list-path " agree"))
      (print (length residue) " class (e) counters"
             (if (empty? residue) "" " -- the gate is that this is zero"))
      (os/exit (if (empty? arrived) 0 1)))
    (do
      (spit list-path text)
      (print "wrote " list-path " -- " (length rows) " counters, "
             (length residue) " in class (e)")
      (os/exit 0))))
