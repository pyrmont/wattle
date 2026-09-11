# Copyright (c) 2026 Calvin Rose
#
# Permission is hereby granted, free of charge, to any person obtaining a copy
# of this software and associated documentation files (the "Software"), to
# deal in the Software without restriction, including without limitation the
# rights to use, copy, modify, merge, publish, distribute, sublicense, and/or
# sell copies of the Software, and to permit persons to whom the Software is
# furnished to do so, subject to the following conditions:
#
# The above copyright notice and this permission notice shall be included in
# all copies or substantial portions of the Software.
#
# THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
# IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
# FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
# AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
# LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING
# FROM, OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS
# IN THE SOFTWARE.

(import ./helper :prefix "" :exit true)
(start-suite)

# Marshal

# 98f2c6f
(def um-lookup (env-lookup (fiber/getenv (fiber/current))))
(def m-lookup (invert um-lookup))

# 0cf10946b
(defn testmarsh [x msg]
  (def marshx (marshal x m-lookup))
  (def out (marshal (unmarshal marshx um-lookup) m-lookup))
  (assert (= (string marshx) (string out)) msg))

(testmarsh nil "marshal nil")
(testmarsh false "marshal false")
(testmarsh true "marshal true")
(testmarsh 1 "marshal small integers")
(testmarsh -1 "marshal integers (-1)")
(testmarsh 199 "marshal small integers (199)")
(testmarsh 5000 "marshal medium integers (5000)")
(testmarsh -5000 "marshal small integers (-5000)")
(testmarsh 10000 "marshal large integers (10000)")
(testmarsh -10000 "marshal large integers (-10000)")
(testmarsh 1.0 "marshal double")
(testmarsh "doctordolittle" "marshal string")
(testmarsh :chickenshwarma "marshal symbol")
(testmarsh @"oldmcdonald" "marshal buffer")
(testmarsh @[1 2 3 4 5] "marshal array")
(testmarsh [tuple 1 2 3 4 5] "marshal tuple")
(testmarsh @{1 2 3 4}  "marshal table")
(testmarsh {1 2 3 4}  "marshal struct")
(testmarsh (fn [x] x) "marshal function 0")
(testmarsh (fn name [x] x) "marshal function 1")
(testmarsh (fn [x] (+ 10 x 2)) "marshal function 2")
(testmarsh (fn thing [x] (+ 11 x x 30)) "marshal function 3")
(testmarsh map "marshal function 4")
(testmarsh reduce "marshal function 5")
(testmarsh (fiber/new (fn [] (yield 1) 2)) "marshal simple fiber 1")
(testmarsh (fiber/new (fn [&] (yield 1) 2)) "marshal simple fiber 2")

# issue #53 - 1147482e6
(def strct {:a @[nil]})
(put (strct :a) 0 strct)
(testmarsh strct "cyclic struct")

# More marshalling code
# issue #53 - 1147482e6
(defn check-image
  "Run a marshaling test using the make-image and load-image functions."
  [x msg]
  (def im (make-image x))
  # (printf "\nimage-hash: %d" (-> im string hash))
  (assert-no-error msg (load-image im)))

(check-image (fn [] (fn [] 1)) "marshal nested functions")
(check-image (fiber/new (fn [] (fn [] 1)))
             "marshal nested functions in fiber")
(check-image (fiber/new (fn [] (fiber/new (fn [] 1))))
             "marshal nested fibers")

# issue #53 - f4908ebc4
(setdyn *lint-warn* :none)
(def issue-53-x
  (fiber/new
    (fn []
      (var y (fiber/new (fn [] (print "1") (yield) (print "2")))))))
(setdyn *lint-warn* nil)

(check-image issue-53-x "issue 53 regression")

# Marshal closure over non resumable fiber
# issue #317 - 7c4ffe9b9
(do
  (defn f1
    [a]
    (defn f1 :shadow [] (++ (a 0)))
    (defn f2 [] (++ (a 0)))
    (error [f1 f2]))
  (def [_ tup] (protect (f1 @[0])))
  (def [f1 f2] :shadow (unmarshal (marshal tup make-image-dict) load-image-dict))
  (assert (= 1 (f1)) "marshal-non-resumable-closure 1")
  (assert (= 2 (f2)) "marshal-non-resumable-closure 2"))

# Marshal closure over currently alive fiber
# issue #317 - 7c4ffe9b9
(do
  (defn f1
    [a]
    (defn f1 :shadow [] (++ (a 0)))
    (defn f2 :shadow [] (++ (a 0)))
    (marshal [f1 f2] make-image-dict))
  (def [f1 f2] :shadow (unmarshal (f1 @[0]) load-image-dict))
  (assert (= 1 (f1)) "marshal-live-closure 1")
  (assert (= 2 (f2)) "marshal-live-closure 2"))

(do
  (var a 1)
  (defn b [x] (+ a x))
  (def c (unmarshal (marshal b)))
  (assert (= 2 (c 1)) "marshal-on-stack-closure 1"))

# Issue #336 cases - don't segfault
# b145d4786
(assert-error "unmarshal errors 1" (unmarshal @"\xd6\xb9\xb9"))
(assert-error "unmarshal errors 2" (unmarshal @"\xd7bc"))
# 5bbd50785
(assert-error "unmarshal errors 3"
              (unmarshal "\xd3\x01\xd9\x01\x62\xcf\x03\x78\x79\x7a"
                         load-image-dict))
# fcc610f53
(assert-error "unmarshal errors 4"
              (unmarshal
                @"\xD7\xCD\0e/p\x98\0\0\x03\x01\x01\x01\x02\0\0\x04\0\xCEe/p../tools
\0\0\0/afl\0\0\x01\0erate\xDE\xDE\xDE\xDE\xDE\xDE\xDE\xDE\xDE\xDE
\xA8\xDE\xDE\xDE\xDE\xDE\xDE\0\0\0\xDE\xDE_unmarshal_testcase3.ja
neldb\0\0\0\xD8\x05printG\x01\0\xDE\xDE\xDE'\x03\0marshal_tes/\x02
\0\0\0\0\0*\xFE\x01\04\x02\0\0'\x03\0\r\0\r\0\r\0\r" load-image-dict))
# XXX: still needed? see 72beeeea
(gccollect)

# ev/chan marshalling
(compwhen (dyn 'ev/chan)
  (def chan (ev/chan 10))
  (ev/give chan chan)
  (def newchan (unmarshal (marshal chan)))
  (def item (ev/take newchan))
  (assert (= item newchan) "ev/chan marshalling"))

# Issue #1488 - marshalling weak values
(testmarsh (array/weak 10) "marsh array/weak")
(testmarsh (table/weak-keys 10) "marsh table/weak-keys")
(testmarsh (table/weak-values 10) "marsh table/weak-values")
(testmarsh (table/weak 10) "marsh table/weak")

# The weak lead bytes are 226 through 232 in every configuration. The event
# loop is a build option and a lead byte is a wire format, so a build that
# cannot produce a threaded abstract still leaves 224 and 225 unused rather
# than reusing them for something else.
(assert (= 226 (in (marshal (table/weak-keys 4)) 0)) "table/weak-keys lead byte")
(assert (= 227 (in (marshal (table/weak-values 4)) 0)) "table/weak-values lead byte")
(assert (= 228 (in (marshal (table/weak 4)) 0)) "table/weak lead byte")
(assert (= 232 (in (marshal (array/weak 4)) 0)) "array/weak lead byte")
(assert (= 229 (in (marshal (table/setproto (table/weak-keys 4) @{})) 0))
        "table/weak-keys with prototype lead byte")
(assert (= 230 (in (marshal (table/setproto (table/weak-values 4) @{})) 0))
        "table/weak-values with prototype lead byte")
(assert (= 231 (in (marshal (table/setproto (table/weak 4) @{})) 0))
        "table/weak with prototype lead byte")

# Now check that gc works with weak containers after marshalling

# Turn off automatic GC for testing weak references
(gcsetinterval 0x7FFFFFFF)

# array
(def a (array/weak 1))
(array/push a @"")
(assert (= 1 (length a)) "array/weak marsh 1")
(def aclone (-> a marshal unmarshal))
(assert (= 1 (length aclone)) "array/weak marsh 2")
(gccollect)
(assert (= 1 (length aclone)) "array/weak marsh 3")
(assert (= 1 (length a)) "array/weak marsh 4")
(assert (= nil (get a 0)) "array/weak marsh 5")
(assert (= nil (get aclone 0)) "array/weak marsh 6")
(assert (deep= a aclone) "array/weak marsh 7")

# table weak keys and values
(def t (table/weak 1))
(def keep-key :key)
(def keep-value :value)
(put t :abc @"")
(put t :key :value)
(assert (= 2 (length t)) "table/weak marsh 1")
(def tclone (-> t marshal unmarshal))
(assert (= 2 (length tclone)) "table/weak marsh 2")
(gccollect)
(assert (= 1 (length tclone)) "table/weak marsh 3")
(assert (= 1 (length t)) "table/weak marsh 4")
(assert (= keep-value (get t keep-key)) "table/weak marsh 5")
(assert (= keep-value (get tclone keep-key)) "table/weak marsh 6")
(assert (deep= t tclone) "table/weak marsh 7")

# table weak keys
(def t :shadow (table/weak-keys 1))
(put t @"" keep-value)
(put t :key @"")
(assert (= 2 (length t)) "table/weak-keys marsh 1")
(def tclone :shadow (-> t marshal unmarshal))
(assert (= 2 (length tclone)) "table/weak-keys marsh 2")
(gccollect)
(assert (= 1 (length tclone)) "table/weak-keys marsh 3")
(assert (= 1 (length t)) "table/weak-keys marsh 4")
(assert (deep= t tclone) "table/weak-keys marsh 5")

# table weak values
(def t :shadow (table/weak-values 1))
(put t @"" keep-value)
(put t :key @"")
(assert (= 2 (length t)) "table/weak-values marsh 1")
(def tclone :shadow (-> t marshal unmarshal))
(assert (= 2 (length tclone)) "table/weak-values marsh 2")
(gccollect)
(assert (= 1 (length t)) "table/weak-value marsh 3")
(assert (deep= (freeze t) (freeze tclone)) "table/weak-values marsh 4")

# tables with prototypes
(def t :shadow (table/weak-values 1))
(table/setproto t @{:abc 123})
(put t @"" keep-value)
(put t :key @"")
(assert (= 2 (length t)) "marsh weak tables with prototypes 1")
(def tclone :shadow (-> t marshal unmarshal))
(assert (= 2 (length tclone)) "marsh weak tables with prototypes 2")
(gccollect)
(assert (= 1 (length t)) "marsh weak tables with prototypes 3")
(assert (deep= (freeze t) (freeze tclone)) "marsh weak tables with prototypes 4")
(assert (deep= (getproto t) (getproto tclone)) "marsh weak tables with prototypes 5")

# A threaded channel marshals and cannot be read back. The portable encoding
# carries the channel's contents; rebuilding a threaded one wants an allocation
# on the threaded heap and a reference count, and the stream has neither.
(compwhen (dyn 'ev/thread-chan)
  (def tchan (ev/thread-chan 4))
  (assert (buffer? (marshal tchan)) "threaded channel marshals")
  (assert-error "cannot unmarshal a threaded channel"
                (unmarshal (marshal tchan)))
  # The unthreaded one is what isolates the flag byte as the cause.
  (assert (= :core/channel (type (unmarshal (marshal (ev/chan 4)))))
          "unthreaded channel round-trips"))

# Marshalling counts its depth: every recursive step is handed one more than
# it was given, and a step above the build's recursion budget is refused. So
# the budget is the last chain that survives and one more is the first that
# does not, and a step that counted two would refuse the first of those. Each
# shape below is asserted at both ends of its own boundary, because the
# boundary is where a miscount shows and the middle of the range is where it
# hides.
#
# The budget is the recursion guard: 1024, and 512 on wasm, whose host call
# stack is smaller than a native thread's. `build.zig` derives it. The shapes
# that cost more than one level per link have their own boundaries below,
# each a fraction of it.
(def budget (if (= :wasm (os/arch)) 512 1024))
(def over (+ budget 1))

# Containers cost one level each. The chain cycles the four so that one pair
# of assertions covers the value path of all of them.
(defn- nest-values [depth]
  (var x 0)
  (for i 0 depth
    (set x (case (% i 4) 0 @[x] 1 [x] 2 @{:k x} 3 {:k x})))
  x)
(assert (buffer? (marshal (nest-values budget))) "nested containers marshal at the budget")
(assert-error "stack overflow" (marshal (nest-values over)))
(assert (buffer? (marshal (unmarshal (marshal (nest-values budget)))))
        "nested containers round-trip at the budget")

# A key is walked before its value, so a chain built through the key position
# reaches the other half of each dictionary.
(defn- nest-keys [depth]
  (var x 0)
  (for i 0 depth (set x (case (% i 2) 0 {x :v} 1 [x])))
  x)
(assert (buffer? (marshal (nest-keys budget))) "nested keys marshal at the budget")
(assert-error "stack overflow" (marshal (nest-keys over)))
(assert (buffer? (marshal (unmarshal (marshal (nest-keys budget)))))
        "nested keys round-trip at the budget")

# A prototype is walked the same way and is the third path into a table.
(defn- nest-protos [depth]
  (var x @{})
  (repeat depth (set x (table/setproto @{} x)))
  x)
(assert (buffer? (marshal (nest-protos budget))) "nested prototypes marshal at the budget")
(assert-error "stack overflow" (marshal (nest-protos over)))
(assert (buffer? (marshal (unmarshal (marshal (nest-protos budget)))))
        "nested prototypes round-trip at the budget")

# A struct prototype is a fourth path, and it is not the table's: the two are
# read by separate arms and only a chain built from structs walks this one.
(defn- nest-struct-protos [depth]
  (var x (struct))
  (repeat depth (set x (struct/with-proto x)))
  x)
(assert (buffer? (marshal (nest-struct-protos budget)))
        "nested struct prototypes marshal at the budget")
(assert-error "stack overflow" (marshal (nest-struct-protos over)))
(assert (buffer? (marshal (unmarshal (marshal (nest-struct-protos budget)))))
        "nested struct prototypes round-trip at the budget")

# A table key, which the chain above reaches only for a struct.
(defn- nest-table-keys [depth]
  (var x 0)
  (repeat depth (set x @{x :v}))
  x)
(assert (buffer? (marshal (nest-table-keys budget))) "nested table keys marshal at the budget")
(assert-error "stack overflow" (marshal (nest-table-keys over)))
(assert (buffer? (marshal (unmarshal (marshal (nest-table-keys budget)))))
        "nested table keys round-trip at the budget")

# A closure costs two levels, the function and the environment holding the one
# below it, so its boundary is half the containers'.
(def closure-budget (div budget 2))
(defn- nest-closures [depth]
  (var x (fn [] 0))
  (repeat depth (let [inner x] (set x (fn [] inner))))
  x)
(assert (buffer? (marshal (nest-closures closure-budget)))
        "nested closures marshal at their half of the budget")
(assert-error "stack overflow" (marshal (nest-closures (+ closure-budget 1))))
(assert (function? (unmarshal (marshal (nest-closures closure-budget))))
        "nested closures round-trip at their half of the budget")

# A link of this chain is a fiber and the closure it runs, and it spends four
# levels, so the boundary is a quarter of the budget. One link fewer than that,
# because the innermost fiber is one of the four as well: the refusal falls at
# a quarter, and the last chain that survives is one short of it. Measured at
# both budgets.
(def fiber-budget (- (div budget 4) 1))
(defn- nest-fibers [depth]
  (var x (fiber/new (fn [] 0)))
  (repeat depth (let [inner x] (set x (fiber/new (fn [] inner)))))
  x)
(assert (buffer? (marshal (nest-fibers fiber-budget)))
        "nested fibers marshal at their share of the budget")
(assert-error "stack overflow" (marshal (nest-fibers (+ fiber-budget 1))))
(assert (fiber? (unmarshal (marshal (nest-fibers fiber-budget))))
        "nested fibers round-trip at their share of the budget")

# A fiber that has run carries a stack, and its frames, their environments and
# the values on them are written by paths a fiber that never started does not
# reach. Resuming each one to its `yield` is what puts a frame on it.
#
# A link here spends four levels as well, and the chain reaches a full quarter
# of the budget: one link more than the unstarted chain above, the innermost
# fiber of this one being `0` rather than a fiber. Measured at both budgets.
(def suspended-budget (div budget 4))
(defn- nest-suspended [depth]
  (var x 0)
  (repeat depth
    (let [inner x]
      (def f (fiber/new (fn [] (yield inner) inner)))
      (resume f)
      (set x f)))
  x)
(assert (buffer? (marshal (nest-suspended suspended-budget)))
        "suspended fibers marshal at their share of the budget")
(assert-error "stack overflow" (marshal (nest-suspended (+ suspended-budget 1))))
(assert (fiber? (unmarshal (marshal (nest-suspended suspended-budget))))
        "suspended fibers round-trip at their share of the budget")

# A frame owns an environment only when something closed over its locals, and
# the frame's environment, the values on it and the closure that holds it are
# each written by a path a frame without one never reaches.
(defn- nest-env-fibers [depth]
  (var x 0)
  (repeat depth
    (let [inner x]
      (def f (fiber/new (fn [] (def held inner) (yield (fn [] held)) held)))
      (resume f)
      (set x f)))
  x)
(assert (buffer? (marshal (nest-env-fibers suspended-budget)))
        "fibers with closed-over frames marshal at their share of the budget")
(assert-error "stack overflow" (marshal (nest-env-fibers (+ suspended-budget 1))))
(assert (fiber? (unmarshal (marshal (nest-env-fibers suspended-budget))))
        "fibers with closed-over frames round-trip at their share of the budget")

# The two booleans have a lead byte each, and nothing above reads either one
# back. A writer that emitted the same byte for both, or a reader that stepped
# the wrong distance past one, would round-trip every value in this file.
(assert (= true (unmarshal (marshal true))) "true round-trips")
(assert (= false (unmarshal (marshal false))) "false round-trips")
# Inside a container, so that what follows the lead byte is read as well: a
# reader that walked two bytes past a boolean would take the next value's lead
# byte for its payload.
(assert (deep= [false true 1] (unmarshal (marshal [false true 1])))
        "booleans round-trip beside another value")

# A double is written little endian on every host, so its bytes are the one
# assertion that fails if the byte order is decided the wrong way round. The
# round trip cannot see it, because a reader that reverses what the writer
# reversed agrees with itself.
(assert (= "\xC8\0\0\0\0\0\0\xF8?" (string (marshal 1.5)))
        "a double is written little endian")

# `marshal` takes four arguments and the fourth is the one that switches
# cycles off. Three arguments is the last call that does not read it.
(assert (= "\x01" (string (marshal 1 @{} @""))) "marshal takes three arguments")
(assert (= "\x01" (string (marshal 1 @{} @"" true))) "marshal takes four")

# A closure whose environment is still on the stack of the fiber that made it
# is written out as though it had already been detached, and that path is
# reached only while that fiber cannot be marshalled. A fiber marshalling from
# inside itself is the case: it is running, so it is alive.
(def detaching (fiber/new (fn [] (def captured 41) (marshal (fn [] captured)))))
(assert (= 41 ((unmarshal (resume detaching))))
        "a closure detaches from the fiber marshalling it")

# The other side of the same field: a suspended fiber whose frame holds an
# environment carries that environment through the wire, and the resumed copy
# reads the value out of it.
(def suspended (fiber/new (fn [] (def held 99) (yield (fn [] held)) held)))
(resume suspended)
(assert (= 99 (resume (unmarshal (marshal suspended))))
        "a frame's environment survives the wire")

(end-suite)
