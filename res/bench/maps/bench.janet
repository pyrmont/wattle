# The small-map corpus: persistent maps against structs, at 2, 8 and 24
# entries.
#
# Written on 2026-09-17 to decide whether structs could be dropped from the
# language, which notes/LANGUAGE.md records with the figures this gave. A
# struct is one allocation with open-addressed lookup. A map was then a CHAMP
# trie, and is now a B-tree, whose small maps are an abstract and one leaf.
# The question is what a small dictionary built at runtime costs, since a
# constant literal folds either way. `sizes.janet` measures the same against
# more sizes, from 2 entries to 400.
#
# Keys are keywords and values are built at runtime, so nothing folds into a
# constant. Both sides are built through a call, `struct` and `hash-map`, so
# the comparison is the structure rather than a literal's opcode; the `lit`
# rows build a struct through the `{...}` literal for reference, and measured
# the same as the call.
#
# The workloads pair up by name, `-struct-` against `-map-`, and the result is
# the ratio of each pair at each size rather than any time on its own. The
# counts are sized for `ReleaseFast`. Once structs are gone the struct rows no
# longer run, and the map rows measure the bulk builder and iteration work
# against the recorded table.

(defn- bench [name f]
  (def start (os/clock :monotonic))
  (f)
  (def stop (os/clock :monotonic))
  (printf "%s %.6f" name (- stop start)))

(def- keys-24 (map |(keyword (string "k" $)) (range 24)))

(defmacro- build-call [ctor n v]
  ~(,ctor ,;(mapcat |[$ v] (take n keys-24))))

(defmacro- build-lit [n v]
  (struct ;(mapcat |[$ v] (take n keys-24))))

(defn- run-size [n reps]
  (def ks (take n keys-24))
  (def s (eval ~(fn [i] (build-call struct ,n i))))
  (def m (eval ~(fn [i] (build-call hash-map ,n i))))
  (def l (eval ~(fn [i] (build-lit ,n i))))
  (def s1 (s 7)) (def s2 (s 7))
  (def m1 (m 7)) (def m2 (m 7))
  (def tab @{})
  (put tab s1 true)
  (put tab m1 true)
  (def last-k (last ks))

  (bench (string "build-struct-" n) (fn [] (for i 0 reps (s i))))
  (bench (string "build-map-" n) (fn [] (for i 0 reps (m i))))
  (bench (string "build-lit-" n) (fn [] (for i 0 reps (l i))))

  (def look (* reps 4))
  (bench (string "get-struct-" n) (fn [] (var a 0) (for i 0 look (+= a (get s1 last-k))) a))
  (bench (string "get-map-" n) (fn [] (var a 0) (for i 0 look (+= a (get m1 last-k))) a))
  (bench (string "miss-struct-" n) (fn [] (var a 0) (for i 0 look (if (get s1 :absent) (++ a))) a))
  (bench (string "miss-map-" n) (fn [] (var a 0) (for i 0 look (if (get m1 :absent) (++ a))) a))

  (def iter (div reps 4))
  (bench (string "each-struct-" n) (fn [] (var a 0) (for i 0 iter (eachp [k v] s1 (+= a v))) a))
  (bench (string "each-map-" n) (fn [] (var a 0) (for i 0 iter (eachp [k v] m1 (+= a v))) a))

  (bench (string "eq-struct-" n) (fn [] (var a 0) (for i 0 reps (if (= s1 s2) (++ a))) a))
  (bench (string "eq-map-" n) (fn [] (var a 0) (for i 0 reps (if (= m1 m2) (++ a))) a))

  (bench (string "key-struct-" n) (fn [] (var a 0) (for i 0 reps (if (get tab s2) (++ a))) a))
  (bench (string "key-map-" n) (fn [] (var a 0) (for i 0 reps (if (get tab m2) (++ a))) a))

  (def upd (div reps 2))
  (bench (string "update-struct-" n) (fn [] (for i 0 upd (struct ;(kvs s1) last-k i))))
  (bench (string "update-map-" n) (fn [] (for i 0 upd (assoc m1 last-k i)))))

(run-size 2 2000000)
(run-size 8 1000000)
(run-size 24 400000)
