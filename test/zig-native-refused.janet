# The three fields the loader compares, one refused module each.
#
# `zig build test` runs this with the three built fixtures' paths as its
# arguments, in the order the loader compares the fields: bits, then the Zig
# version, then the interface fingerprint. Each fixture reports a
# configuration it was not built with, so each load fails, and the message
# names the field that differed. `test/module-load/report.zig` says how a
# fixture lies.
#
# `test/zig-native.janet` and the three examples are the positive case: a
# module built through `module.entry` reports what it was built with and
# loads.

(def args (dyn *args*))
(def cases
  [["bits" (get args 1)]
   ["zig version" (get args 2)]
   ["api version" (get args 3)]])

(each [field path] cases
  (assert (string? path) (string "no fixture was given for the " field " case"))
  (def [ok result] (protect (native path @{})))
  (assert (not ok) (string path " loaded, and a " field " mismatch should refuse it"))
  (def message (string result))
  (assert (string/find (string "config mismatch - " field " - ") message)
          (string "the refusal should name " field ", and says: " message))
  (assert (string/find "native needs to be recompiled!" message)
          (string "the refusal should say what to do, and says: " message)))
