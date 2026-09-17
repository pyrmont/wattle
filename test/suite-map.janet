(import ./helper :prefix "")

(start-suite)

# Construction

(def m (hash-map :a 1 :b 2 :c 3))
(assert (= :core/map (type m)) "a map is a core/map")
(assert (= 3 (length m)) "map length")
(assert (= 0 (length (hash-map))) "empty map length")
(assert (= 2 (length (hash-map :a 1 :a 2 :b 3))) "a repeated key is one entry")
(assert (= 2 (get (hash-map :a 1 :a 2) :a)) "a later value replaces an earlier one")
(assert (= 1 (length (hash-map :a 1 :b nil))) "a nil value adds no entry")
(assert (= 0 (length (hash-map :a 1 :a nil))) "a later nil value removes the key")
(assert-error-value "an odd number of arguments"
  "expected an even number of keys and values, got 3" (hash-map :a 1 :b))
(assert-error-value "a nil key" "cannot use nil as a key" (hash-map nil 1))
(assert-error-value "a NaN key" "cannot use nan as a key" (hash-map math/nan 1))

(def s (hash-set 1 2 3))
(assert (= :core/set (type s)) "a set is a core/set")
(assert (= 3 (length s)) "set length")
(assert (= 0 (length (hash-set))) "empty set length")
(assert (= 2 (length (hash-set 1 1 2))) "a repeated element is one element")
(assert-error-value "a nil element" "cannot use nil as a key" (hash-set 1 nil))
(assert-error "a NaN element" (hash-set math/nan))

# Reading

(assert (= 1 (get m :a)) "get")
(assert (nil? (get m :z)) "get a missing key")
(assert (= :dflt (get m :z :dflt)) "get a missing key with a default")
(assert (= 2 (in m :b)) "in")
(assert (nil? (in m :z)) "in a missing key gives nil, as for a struct")
(assert (nil? (get m nil)) "get nil")
(assert (nil? (get m math/nan)) "get NaN")
(assert (has-key? m :c) "has-key?")
(assert (not (has-key? m :z)) "has-key? of a missing key")
(assert (not (indexed? m)) "a map is not indexed")
(assert (dictionary? m) "a map is a dictionary")
(assert (not (dictionary? s)) "a set is not a dictionary")
(assert (deep= @[:a :b :c] (sort (keys m))) "keys")
(assert (deep= @[1 2 3] (sort (values m))) "values")
(assert (deep= @[[:a 1] [:b 2] [:c 3]] (sort (pairs m))) "pairs")
(def seen @{})
(eachp [k v] m (put seen k v))
(assert (deep= @{:a 1 :b 2 :c 3} seen) "eachp")
(assert (= 6 (sum (values m))) "sum of values")

(assert (= 2 (get s 2)) "a set's get gives the element")
(assert (nil? (get s 4)) "get a missing element")
(assert (nil? (in s 4)) "in a missing element")
(assert (has-key? s 1) "has-key? is membership")
(assert (deep= @[1 2 3] (sort (keys s))) "a set's keys are its elements")
(assert (deep= @[1 2 3] (sort (values s))) "a set's values are its elements")
(def elements @[])
(each x s (array/push elements x))
(assert (deep= @[1 2 3] (sort elements)) "each gives a set's elements")
(assert (deep= @[2] (filter |(has-key? s $) [0 2 4])) "a set as a predicate")

(def big (hash-set ;(range 5000)))
(gccollect)
(assert (= 5000 (length big)) "a large set")
(assert (= (sum (range 5000)) (sum (keys big))) "every element of a large set")
(assert (all |(= $ (get big $)) (range 5000)) "every element found")

# Updating

(def m2 (assoc m :d 4 :a 10))
(assert (= (hash-map :a 10 :b 2 :c 3 :d 4) m2) "assoc several")
(assert (= (hash-map :a 1 :b 2 :c 3) m) "assoc leaves the original")
(assert (= (hash-map :b 2 :c 3) (assoc m :a nil)) "assoc nil removes the key")
(assert (= m (assoc m :z nil)) "assoc nil of a missing key")
(assert-error-value "assoc a nil key" "cannot use nil as a key" (assoc m nil 1))
(assert-error "assoc a NaN key" (assoc m math/nan 1))
(assert-error "assoc a dangling key" (assoc m :a 1 :b))
(assert (= (hash-map :c 3) (dissoc m :a :b :z)) "dissoc")
(assert (= m (dissoc m :z)) "dissoc a missing key")
(assert (= m (dissoc m nil)) "dissoc nil")
(assert (= (hash-map :a 1 :b 2 :c 3) m) "dissoc leaves the original")
(assert-error-value "conj a map"
  "bad slot #0, expected vector or core/set, got <core/map :a 1>"
  (conj (hash-map :a 1) [:d 4]))
(assert-error "dissoc a set" (dissoc s 1))

(assert (= (hash-set 1 2 3 4) (conj s 4 1)) "conj a set")
(assert (= (hash-set 1 2 3) s) "conj leaves the original")
(assert (= (hash-set 3) (disj s 1 2 9)) "disj")
(assert-error-value "conj nil into a set" "cannot use nil as a key" (conj s nil))
(assert-error-value "assoc a set"
  "bad slot #0, expected vector or core/map, got <core/set 1>"
  (assoc (hash-set 1) 1 2))
(assert-error "disj a map" (disj m :a))

(var grown (hash-map))
(for i 0 3000 (set grown (assoc grown i (* i i))))
(gccollect)
(assert (= 3000 (length grown)) "assoc one at a time")
(assert (all |(= (* $ $) (get grown $)) (range 3000)) "every value after growing")
(var shrunk grown)
(loop [i :range [0 3000 2]] (set shrunk (dissoc shrunk i)))
(assert (= 1500 (length shrunk)) "dissoc one at a time")
(assert (= 3000 (length grown)) "dissoc leaves every earlier version")

# Transients

(def tm (transient (hash-map :a 1 :b 2)))
(assert (= :core/transient (type tm)) "a transient of a map is a core/transient")
(assert (= tm (assoc! tm :c 3 :a 10)) "assoc! returns the transient")
(assert (= tm (dissoc! tm :b :z nil)) "dissoc! returns the transient")
(assert (= 2 (length tm)) "transient map length")
(assert (= 10 (get tm :a)) "transient map get")
(assert (nil? (in tm :b)) "transient map in a missing key")
(assert (= :dflt (get tm :b :dflt)) "transient map get with a default")
(assoc! tm :c nil)
(assert (= 1 (length tm)) "assoc! nil removes the key")
(assert-error-value "assoc! a nil key" "cannot use nil as a key" (assoc! tm nil 1))
(assert-error "assoc! a NaN key" (assoc! tm math/nan 1))
(assert-error-value "conj! a transient of a map"
  "expected a transient of a vector or a set, got a transient of a map"
  (conj! tm [:d 4]))
(assert-error-value "disj! a transient of a map"
  "expected a transient of a set, got a transient of a map" (disj! tm :a))
(assert-error "each over a transient map" (each _ tm))
(assert-error "keys of a transient map" (keys tm))
(def tm-base (hash-map :a 1 :b 2))
(def tm2 (transient tm-base))
(assoc! tm2 :a 99)
(dissoc! tm2 :b)
(assert (= (hash-map :a 99) (persistent! tm2)) "persistent! of a map")
(assert (= (hash-map :a 1 :b 2) tm-base) "a transient leaves its map")
(assert-error-value "dissoc! after persistent!"
  "transient used after persistent!" (dissoc! tm2 :a))

(def ts (transient (hash-set 1 2)))
(assert (= ts (conj! ts 3 4 1)) "conj! returns the transient")
(assert (= ts (disj! ts 2 9 nil)) "disj! returns the transient")
(assert (= 3 (length ts)) "transient set length")
(assert (= 3 (get ts 3)) "transient set get gives the element")
(assert (nil? (in ts 2)) "transient set in a missing element")
(assert-error-value "conj! nil into a transient set"
  "cannot use nil as a key" (conj! ts nil))
(assert-error-value "assoc! a transient of a set"
  "expected a transient of a vector or a map, got a transient of a set"
  (assoc! ts 1 2))
(assert-error-value "dissoc! a transient of a set"
  "expected a transient of a map, got a transient of a set" (dissoc! ts 1))
(assert-error-value "dissoc! a transient of a vector"
  "expected a transient of a map, got a transient of a vector"
  (dissoc! (transient (vector 1)) 0))
(assert (= (hash-set 1 3 4) (persistent! ts)) "persistent! of a set")
(assert-error "disj! after persistent!" (disj! ts 1))
(assert-error-value "transient of a number"
  "bad slot #0, expected vector, core/map or core/set, got 5"
  (transient 5))

(def batch (transient (hash-map)))
(for i 0 5000 (assoc! batch i (* 2 i)))
(gccollect)
(loop [i :range [0 5000 2]] (dissoc! batch i))
(def batched (persistent! batch))
(def direct (hash-map ;(mapcat |[$ (* 2 $)] (range 1 5000 2))))
(assert (= direct batched) "a long batch")
(assert (= (hash direct) (hash batched)) "a batch hashes as the map it equals")
(def again (transient batched))
(assoc! again 1 :changed)
(assert (= 2 (get batched 1)) "a second transient leaves the first's map")

# Equality, order and hash

(assert (= (hash-map) (hash-map)) "empty maps are equal")
(assert (= (hash-map :a 1 :b 2) (hash-map :b 2 :a 1)) "maps equal in any order")
(assert (= (hash (hash-map :a 1 :b 2)) (hash (hash-map :b 2 :a 1)))
  "equal maps hash alike")
(assert (not= (hash-map :a 1) (hash-map :a 2)) "unequal values")
(assert (not= (hash-map :a 1) (hash-map :b 1)) "unequal keys")
(assert (not= (hash-map 1 1) (hash-set 1)) "a map is not a set")
(assert (not= (hash-map :a 1) {:a 1}) "a map is not a struct")
(assert (= (hash-set 1 2 3) (hash-set 3 2 1)) "sets equal in any order")
(assert (= shrunk (hash-map ;(mapcat |[$ (* $ $)] (range 1 3000 2))))
  "a map shrunk by dissoc equals one built directly")
(assert (= (hash shrunk) (hash (hash-map ;(mapcat |[$ (* $ $)] (range 1 3000 2)))))
  "and hashes alike")
(assert (= :found (get {(hash-map :k [1 2]) :found} (hash-map :k [1 2])))
  "a map as a struct key")
(assert (= :found (get @{(hash-set 1 2) :found} (hash-set 2 1)))
  "a set as a table key")
(assert (= (hash-set (hash-map :a 1)) (hash-set (hash-map :a 1)))
  "nested collections compare as values")
(assert (= -1 (cmp (hash-map :a 1) (hash-map :a 1 :b 2))) "fewer entries order first")
(assert (= 0 (cmp (hash-map :a 1 :b 2) (hash-map :b 2 :a 1))) "cmp of equal maps")
(def ordered (sort @[(hash-set 1 2) (hash-set) (hash-set 3)]))
(assert (= (hash-set) (in ordered 0)) "sort")

# Marshalling

(defn round-trip [x] (unmarshal (marshal x)))
(assert (= m (round-trip m)) "marshal a map")
(assert (= s (round-trip s)) "marshal a set")
(assert (= (hash-map) (round-trip (hash-map))) "marshal an empty map")
(assert (= :core/map (type (round-trip m))) "a marshalled map is a map")
(assert (= :core/set (type (round-trip s))) "a marshalled set is a set")
(assert (= big (round-trip big)) "marshal a large set")
(assert (= (hash grown) (hash (round-trip grown))) "a marshalled map hashes alike")
(assert (= batched (round-trip batched)) "marshal a map a transient made")
(def mixed (hash-map "s" 1.5 'sym @[1] [1 2] {:a 1} (vector 1) (hash-set :x)))
(def mixed-back (round-trip mixed))
(assert (= 4 (length mixed-back)) "marshal mixed entries")
(assert (deep= @[1] (get mixed-back 'sym)) "marshal an array value")
(assert (= (hash-set :x) (get mixed-back (vector 1))) "marshal nested collections")
(def pair (round-trip @[s s]))
(assert (= (in pair 0) (in pair 1)) "a set marshalled twice")
(def cyc @{})
(def holder (hash-map :t cyc))
(put cyc holder :found)
(def holder-back (round-trip holder))
(assert (= :found (get (in holder-back :t) holder-back))
  "a map used as a key in its own value")
(assert-error "marshal a transient map" (marshal (transient m)))
(assert-error "marshal a transient set" (marshal (transient s)))

# Printing

(assert (= "<core/map :a 1>" (describe (hash-map :a 1))) "describe a map")
(assert (= "<core/set 1>" (describe (hash-set 1))) "describe a set")
(assert (= "<core/map >" (describe (hash-map))) "describe an empty map")
(assert (= "<core/set <vector 1>>" (describe (hash-set (vector 1))))
  "describe nested")
(assert (= "<core/map :a 1>" (string/format "%q" (hash-map :a 1))) "format")

(end-suite)
