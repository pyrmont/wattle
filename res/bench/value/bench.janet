# Phase 10 Part 17b's benchmark corpus: cfunction entry.
#
# The Phase 9 corpus measures the interpreter, and what 17b changed is what
# happens in the first two or three instructions of a *cfunction*: an arity
# check and a getter per argument, which were calls across a compilation
# boundary and are now ordinary in-module calls. Nine of that corpus's ten
# workloads cannot see it, and its tenth is a PEG match, which is the control.
#
# So these workloads are chosen for the opposite property: as little work per
# call as possible, so that the entry cost is the largest share of it. Each
# calls a cfunction whose body is a few instructions, several million times.
# A regression here is what the argument layer costs; an improvement is what
# the fold gives back.
#
# The counts are sized for `ReleaseFast`, where every workload lands between a
# tenth of a second and a quarter of one. They were five times smaller when
# this file was written against a Debug build, which put them at twenty-six to
# forty-three milliseconds -- inside the harness floor Part 17b measured, so
# the corpus could not resolve its own subject.

(defn- bench [name f]
  (def start (os/clock :monotonic))
  (f)
  (def stop (os/clock :monotonic))
  (printf "%s %.6f" name (- stop start)))

# One fixarity plus one getnumber, and a body of one instruction. The purest
# entry-cost measurement in the corpus.
(defn- onearg []
  (var acc 0.0)
  (for i 0 15000000
    (set acc (math/floor 1.5)))
  acc)

# One fixarity plus two getters, one of them a byte view.
(defn- twoarg []
  (def s "abcdefghij")
  (var n 0)
  (for i 0 5000000
    (set n (+ n (length (string/slice s 2)))))
  n)

# Three arguments, a slice range, and the two range helpers behind it.
(defn- threearg []
  (def s "abcdefghij")
  (var n 0)
  (for i 0 5000000
    (set n (+ n (length (string/slice s 1 4)))))
  n)

# A getbuffer plus a getinteger, and a mutation rather than an allocation, so
# the collector stays out of the measurement.
(defn- buffered []
  (def b @"")
  (for i 0 10000000
    (buffer/clear b)
    (buffer/push-byte b 65))
  (length b))

# An optional argument taken from its default, which is the `Opt` wrapper's
# fall-through rather than the getter's.
(defn- optional []
  (def s "abcabcabc")
  (var n 0)
  (for i 0 7000000
    (set n (+ n (or (string/find "b" s) 0))))
  n)

# An abstract getter: janet_getabstract plus the type check behind it.
(defn- abstract []
  (def r (math/rng 7))
  (var acc 0.0)
  (for i 0 20000000
    (set acc (math/rng-uniform r)))
  acc)

# A variadic arity check -- janet_arity rather than janet_fixarity -- with the
# minimum of work behind it.
(defn- variadic []
  (var n 0)
  (for i 0 3000000
    (set n (+ n (length (string "a" "b")))))
  n)

# The control: a PEG match, which enters one cfunction and then spends all its
# time inside the engine. It should not move, and if it does the corpus has not
# measured anything -- Part 16's rule.
(defn- control []
  (def g (peg/compile '(some (range "az"))))
  (var n 0)
  (for i 0 1000000
    (when (peg/match g "abcdefghijklmnopqrstuvwxyz") (set n (+ n 1))))
  n)

# Phase 10 Part 17d converted `janet_sandbox_assert`, which every `os/`, `io/`,
# `net/` and `ffi/` cfunction opens with, and there is deliberately no workload
# for it here. Every cfunction that pays the check also makes a system call:
# `(os/cwd)` runs at five microseconds an iteration, against forty nanoseconds
# for `onearg` below, so the check is three orders of magnitude beneath the
# noise of the cheapest thing that performs it. A corpus that cannot resolve
# what it is aimed at should not pretend to; the honest statement is that the
# conversion turned a predicted-not-taken branch on a VM field into the same
# branch, and nothing in the tree can see the difference.
(bench "onearg" onearg)
(bench "twoarg" twoarg)
(bench "threearg" threearg)
(bench "buffered" buffered)
(bench "optional" optional)
(bench "abstract" abstract)
(bench "variadic" variadic)
(bench "control" control)
