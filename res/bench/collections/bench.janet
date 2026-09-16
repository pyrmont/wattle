# The indexed protocol's benchmark corpus: reading a collection's elements.
#
# The Phase 9 corpus measures the interpreter and the Phase 10 one measures
# cfunction entry. Neither contains a splice, an `apply` or an `array/concat`,
# so neither can see the sites the indexed protocol converts: both corpora sat
# flat through a change that made one of these workloads 4.6 times faster and
# another 13% slower.
#
# So these workloads are chosen to read a collection's elements and do as
# little else as they can. Each family runs at three sizes, because the cost
# the protocol adds is per call and the cost it removes is per element, and
# only the curve separates them. A regression at three elements and an
# improvement at a thousand is the expected shape of a conversion; a
# regression at a thousand is not.
#
# `control` is the control: a table put and get, which reads no elements and
# reaches nothing the protocol touches. `concat-single` is the second check,
# the arm of `array/concat` that appends a part which is not indexed, and it
# is expected to stay where it is while its neighbours move.
#
# The counts are sized for `ReleaseFast` against the tree that added them,
# where each workload lands near an eighth of a second. An arm that is several
# times slower on the copy-heavy workloads takes proportionally longer, which
# is the point of having them.

(defn- bench [name f]
  (def start (os/clock :monotonic))
  (f)
  (def stop (os/clock :monotonic))
  (printf "%s %.6f" name (- stop start)))

(defn- sink [& xs] (length xs))

(def- small [1 2 3])
(def- medium (tuple ;(range 32)))
(def- large (tuple ;(range 1024)))

# Three elements spliced, which is the shape almost every splice in real code
# has and where the per-call cost is the whole cost.
(defn- splice-small []
  (var acc 0)
  (for i 0 5000000 (set acc (+ acc (sink ;small))))
  acc)

# Thirty-two, where the copy begins to matter.
(defn- splice-medium []
  (var acc 0)
  (for i 0 1500000 (set acc (+ acc (sink ;medium))))
  acc)

# A thousand: the copy, and the stack growth on the first call.
(defn- splice-large []
  (var acc 0)
  (for i 0 60000 (set acc (+ acc (sink ;large))))
  acc)

# `apply` reaches the same opcode through its own assembled function.
(defn- apply-small []
  (var acc 0)
  (for i 0 4000000 (set acc (+ acc (apply sink small))))
  acc)

# Three elements onto a fresh array, where the allocation is most of the cost.
(defn- concat-small []
  (var acc 0)
  (for i 0 2500000 (set acc (+ acc (length (array/concat @[] small)))))
  acc)

(defn- concat-medium []
  (var acc 0)
  (for i 0 1500000 (set acc (+ acc (length (array/concat @[] medium)))))
  acc)

(defn- concat-large []
  (var acc 0)
  (for i 0 250000 (set acc (+ acc (length (array/concat @[] large)))))
  acc)

# Appending onto an array that already has room, which is the case with no
# allocation to hide behind and the one a reading cost shows up in first.
(defn- concat-growing []
  (var total 0)
  (for j 0 9000
    (def a @[])
    (for i 0 1000 (array/concat a small))
    (set total (+ total (length a))))
  total)

# The arm for a part that is not indexed, which no conversion touches.
(defn- concat-single []
  (var acc 0)
  (for i 0 2000000 (set acc (+ acc (length (array/concat @[] :a :b :c)))))
  acc)

(defn- join-small []
  (var acc 0)
  (for i 0 2500000 (set acc (+ acc (length (array/join @[] small)))))
  acc)

# tuple/join counts every argument, allocates, fills the slots with nil and
# then copies, so it reads each argument twice and writes each slot twice.
(defn- tuple-join-small []
  (var acc 0)
  (for i 0 2600000 (set acc (+ acc (length (tuple/join small small)))))
  acc)

(defn- tuple-join-large []
  (var acc 0)
  (for i 0 50000 (set acc (+ acc (length (tuple/join large)))))
  acc)

# The slice bindings read a window of their argument rather than the whole of
# it, so a run at either end of the window is cut to fit.
(defn- tuple-slice-small []
  (var acc 0)
  (for i 0 3500000 (set acc (+ acc (length (tuple/slice small 1)))))
  acc)

(defn- tuple-slice-large []
  (var acc 0)
  (for i 0 50000 (set acc (+ acc (length (tuple/slice large 1 1023)))))
  acc)

(defn- array-slice-large []
  (var acc 0)
  (for i 0 370000 (set acc (+ acc (length (array/slice large 1 1023)))))
  acc)

# The control: a put and a get on a table, reading no elements.
(defn- control []
  (def t @{})
  (var acc 0)
  (for i 0 7000000
    (put t :k i)
    (set acc (+ acc (get t :k))))
  acc)

(bench "splice-small" splice-small)
(bench "splice-medium" splice-medium)
(bench "splice-large" splice-large)
(bench "apply-small" apply-small)
(bench "concat-small" concat-small)
(bench "concat-medium" concat-medium)
(bench "concat-large" concat-large)
(bench "concat-growing" concat-growing)
(bench "concat-single" concat-single)
(bench "join-small" join-small)
(bench "tuple-join-small" tuple-join-small)
(bench "tuple-join-large" tuple-join-large)
(bench "tuple-slice-small" tuple-slice-small)
(bench "tuple-slice-large" tuple-slice-large)
(bench "array-slice-large" array-slice-large)
(bench "control" control)
