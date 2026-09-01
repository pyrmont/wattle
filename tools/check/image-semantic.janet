#!/usr/bin/env janet
# Compare two core images by what they *mean*, with source positions set aside.
#
# The byte comparison `tools/check/image-diff.janet` makes is the right oracle
# for a marshal-width change and the wrong one for Phase 14: the image records
# the file and line each cfunction was registered on, so every increment that
# adds or removes a line above a registration moves the image without changing
# anything a Janet program can observe.
#
# So this compares the unmarshalled environments instead, and reports the two
# populations separately:
#
#   * bindings whose value, docstring, or any other attribute differs -- a real
#     divergence, and the thing the image is the oracle for;
#   * bindings whose only difference is the line a cfunction sits on.
#
#     image-oracle.janet OLD.bin NEW.bin

(defn- env-of [path]
  (load-image (slurp path)))

(defn- strip-pos [entry]
  (if (table? entry)
    (let [t (table/clone entry)]
      (put t :source-map nil)
      t)
    entry))

(defn- describe [v]
  # A cfunction or function compares by identity across two images, which is
  # never equal.  What is comparable is what it prints as -- the name Janet
  # gave it -- plus, for a Janet function, its bytecode.
  (case (type v)
    :function (string "fn " (disasm v :name) " " (string/format "%q" (disasm v :bytecode)))
    :cfunction (string "cfn " (string/format "%q" v))
    (string/format "%q" v)))

(defn- flatten-entry [entry]
  (def out @{})
  (when (table? entry)
    (eachp [k v] entry
      (unless (= k :source-map)
        (put out k (describe v)))))
  out)

(defn main [_ old-path new-path]
  (def a (env-of old-path))
  (def b (env-of new-path))
  (def names (distinct (array/concat @[] (keys a) (keys b))))
  (var real 0)
  (var moved 0)
  (each name (sort names)
    (def ea (get a name))
    (def eb (get b name))
    (cond
      (nil? ea) (do (++ real) (print "  + only in new: " name))
      (nil? eb) (do (++ real) (print "  - only in old: " name))
      (do
        (def fa (flatten-entry ea))
        (def fb (flatten-entry eb))
        (unless (deep= fa fb)
          (++ real)
          (print "  ! differs: " name)
          (eachk k (merge fa fb)
            (unless (= (get fa k) (get fb k))
              (printf "      %v: %.120s" k (string (get fa k)))
              (printf "      %v: %.120s" k (string (get fb k))))))
        (unless (deep= (get ea :source-map) (get eb :source-map))
          (++ moved)))))
  (printf "\n%d bindings compared" (length names))
  (printf "%d moved source position only" moved)
  (printf "%d real divergences" real)
  (os/exit (if (zero? real) 0 1)))
