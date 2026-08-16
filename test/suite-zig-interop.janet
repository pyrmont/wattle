(import ./helper :prefix "")

(start-suite 1)

(def interop-values
  [nil true false (fiber/new (fn [] nil)) 42 1.5 "string" 'symbol :keyword
   @[1 2] '(1 2) @{:a 1} {:a 1} @"buffer"
   (fn [x] x) print stdout])

(each value interop-values
  (assert (= value (zig/identity value))))

(assert (= 3 (zig/length "abc")))
(assert (= 3 (zig/length 'abc)))
(assert (= 3 (zig/length :abc)))
(assert (= 2 (zig/length @[1 2])))
(assert (= 2 (zig/length '(1 2))))
(assert (= 1 (zig/length @{:a 1})))
(assert (= 1 (zig/length {:a 1})))
(assert (= 3 (zig/length @"abc")))

(compwhen (dyn 'ffi/native)
  (def pointer (ffi/malloc 1))
  (defer (ffi/free pointer)
    (assert (= pointer (zig/identity pointer)))))

(assert (= 42 (zig/call (fn [x] (+ x 1)) 41)))
(assert (deep= @["alive"] (zig/rooted)))

(def callback-error
  (try (zig/call (fn [_] (error "callback failed")) nil)
       ([err] err)))
(assert (string/find "callback failed" callback-error))

(def zig-error
  (try (zig/fail "zig failed safely")
       ([err] err)))
(assert (= "zig failed safely" zig-error))

(end-suite)
