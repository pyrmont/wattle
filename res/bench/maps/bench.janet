# The small-map corpus: a persistent map at 2, 8 and 24 entries.
#
# Written on 2026-09-17 to decide whether structs could be dropped from the
# language, which notes/LANGUAGE.md records with the figures this gave against
# a struct. Structs were dropped on 2026-09-18, so the struct rows are gone
# and what is left measures one binary against another. `sizes.janet`
# measures the same over more sizes, from 2 entries to 400.
#
# Keys are keywords and values are built at runtime, so nothing folds into a
# constant. The `call` rows build through `hash-map` and the `lit` rows
# through the `{...}` literal, which is the opcode rather than the call; the
# two measured the same when the literal was a struct's.
#
# The counts are sized for `ReleaseFast`.

(defn- bench [name f]
  (def start (os/clock :monotonic))
  (f)
  (def stop (os/clock :monotonic))
  (printf "%s %.6f" name (- stop start)))

(def- keys-24 (map |(keyword (string "k" $)) (range 24)))

(defmacro- build-call [ctor n v]
  ~(,ctor ,;(mapcat |[$ v] (take n keys-24))))

(defmacro- build-lit [n v]
  (hash-map ;(mapcat |[$ v] (take n keys-24))))

(defn- run-size [n reps]
  (def ks (take n keys-24))
  (def m (eval ~(fn [i] (build-call hash-map ,n i))))
  (def l (eval ~(fn [i] (build-lit ,n i))))
  (def m1 (m 7)) (def m2 (m 7))
  (def tab @{})
  (put tab m1 true)
  (def last-k (last ks))

  (bench (string "build-call-" n) (fn [] (for i 0 reps (m i))))
  (bench (string "build-lit-" n) (fn [] (for i 0 reps (l i))))

  (def look (* reps 4))
  (bench (string "get-map-" n) (fn [] (var a 0) (for i 0 look (+= a (get m1 last-k))) a))
  (bench (string "miss-map-" n) (fn [] (var a 0) (for i 0 look (if (get m1 :absent) (++ a))) a))

  (def iter (div reps 4))
  (bench (string "each-map-" n) (fn [] (var a 0) (for i 0 iter (eachp [k v] m1 (+= a v))) a))

  (bench (string "eq-map-" n) (fn [] (var a 0) (for i 0 reps (if (= m1 m2) (++ a))) a))

  (bench (string "key-map-" n) (fn [] (var a 0) (for i 0 reps (if (get tab m2) (++ a))) a))

  (def upd (div reps 2))
  (bench (string "update-map-" n) (fn [] (for i 0 upd (assoc m1 last-k i)))))

(run-size 2 2000000)
(run-size 8 1000000)
(run-size 24 400000)
