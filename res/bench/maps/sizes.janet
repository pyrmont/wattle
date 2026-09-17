# The map sizes corpus: persistent maps against structs, from 2 entries to
# 400, reading, building and updating.
#
# Written on 2026-09-17 when maps became B-trees, to measure the change over
# the sizes where a CHAMP trie had been slow to build. notes/LANGUAGE.md
# records the figures. Keys are keywords and values are built at runtime, so
# nothing folds into a constant, and both sides are built through a call.
#
# The workloads pair up by name, `-struct-` against `-map-`, and the result is
# the ratio of each pair at each size. A struct is updated by rebuilding it
# with one more pair, which is what a struct offers. The counts are sized for
# `ReleaseFast`.

(defn- bench [name f]
  (def start (os/clock :monotonic))
  (f)
  (def stop (os/clock :monotonic))
  (printf "%s %.6f" name (- stop start)))

(def- all-keys (map |(keyword (string "k" $)) (range 400)))

(defn- run-size [n reps]
  (def ks (take n all-keys))
  (def kinds [["struct" 'struct (fn [m k v] (struct ;(kvs m) k v))]
              ["map" 'hash-map assoc]])
  (each [name ctor up] kinds
    (def f (eval ~(fn [i] (,ctor ,;(mapcat |[$ 'i] ks)))))
    (def m (f 7))
    (bench (string "build-" name "-" n) (fn [] (for i 0 reps (f i))))
    (def look (div (* reps 4) n))
    (bench (string "get-" name "-" n) (fn [] (var a 0) (each k ks (for i 0 look (+= a (get m k)))) a))
    (bench (string "miss-" name "-" n) (fn [] (var a 0) (for i 0 (* reps 4) (if (get m :absent) (++ a))) a))
    (def iter (div (* reps 6) n))
    (bench (string "each-" name "-" n) (fn [] (var a 0) (for i 0 iter (eachp [k v] m (+= a v))) a))
    (def upd (div reps 2))
    (def mid (ks (div n 2)))
    (bench (string "update-" name "-" n) (fn [] (for i 0 upd (up m mid i))))
    (bench (string "insert-" name "-" n) (fn [] (for i 0 upd (up m :new-key i))))))

(run-size 2 1000000)
(run-size 8 500000)
(run-size 16 300000)
(run-size 24 200000)
(run-size 32 150000)
(run-size 50 100000)
(run-size 100 50000)
(run-size 200 25000)
(run-size 400 12000)
