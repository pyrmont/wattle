(import ./helper :prefix "")

(start-suite)

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

# The client's getline reads one line into the buffer it is given, prompt on
# stderr, and leaves the buffer empty at the end of input.
(compwhen (dyn 'os/spawn)
  (def child
    `(def b @"old")
     (def r (getline "p> " b))
     (prin (if (= r b) "same" "other") "|" b)
     (prin "|" (getline "q> "))
     (prin "|" (length (getline)))`)
  (def p (os/spawn [(dyn *executable*) "-e" child] :p {:in :pipe :out :pipe :err :pipe}))
  (:write (p :in) "hello\nworld\n")
  (:close (p :in))
  (def out (:read (p :out) :all))
  (def err (:read (p :err) :all))
  (assert (= 0 (os/proc-wait p)) "the getline child exits cleanly")
  (assert (= "same|hello\n|world\n|0" (string out)) "getline reads a line at a time")
  (assert (= "p> q> " (string err)) "and writes each prompt"))

(end-suite)
