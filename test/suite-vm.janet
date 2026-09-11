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

# More fiber semantics
# 0fd9224e4
(var myvar 0)
(defn fiberstuff [&]
  (++ myvar)
  (def f (fiber/new (fn [&] (++ myvar) (debug) (++ myvar))))
  (resume f)
  (++ myvar))

(def myfiber (fiber/new fiberstuff :dey))

(assert (= myvar 0) "fiber creation does not call fiber function")
(resume myfiber)
(assert (= myvar 2) "fiber debug statement breaks at proper point")
(assert (= (fiber/status myfiber) :debug) "fiber enters debug state")
(resume myfiber)
(assert (= myvar 4) "fiber resumes properly from debug state")
(assert (= (fiber/status myfiber) :dead)
        "fiber properly dies from debug state")

# yield tests
# 171c0ce
(def t (fiber/new (fn [&] (yield 1) (yield 2) 3)))

(assert (= 1 (resume t)) "initial transfer to new fiber")
(assert (= 2 (resume t)) "second transfer to fiber")
(assert (= 3 (resume t)) "return from fiber")
(assert (= (fiber/status t) :dead) "finished fiber is dead")

# A stack ceiling of zero is a ceiling, and below zero is refused.
(def capped (fiber/new (fn [] 1)))
(fiber/setmaxstack capped 0)
(assert (= 0 (fiber/maxstack capped)) "fiber/setmaxstack takes 0")
(assert-error "fiber/setmaxstack refuses -1" (fiber/setmaxstack capped -1))

# A fiber's function takes at most one argument, the first resume value.
(assert-error-value "fiber/new refuses a binary function"
                    "fiber function must accept 0 or 1 arguments"
                    (fiber/new (fn [a _b] a)))

# Fix yields inside nested fibers
# 909c906
(def yielder
  (coro
    (defer (yield :end)
      (repeat 5 (yield :item)))))
(def items (seq [x :in yielder] x))
(assert (deep= @[:item :item :item :item :item :end] items)
        "yield within nested fibers")

# Calling non functions
# b9c0fc820
(assert (= 1 ({:ok 1} :ok)) "calling struct")
(assert (= 2 (@{:ok 2} :ok)) "calling table")
(assert (= :bad (try ((identity @{:ok 2}) :ok :no) ([_err] :bad)))
        "calling table too many arguments")
(assert (= :bad (try ((identity :ok) @{:ok 2} :no) ([_err] :bad)))
        "calling keyword too many arguments")
(assert (= :oops (try ((+ 2 -1) 1) ([_err] :oops)))
        "calling number fails")

# Method test
# d5bab7262
(def Dog @{:bark (fn bark [self what]
                   (string (self :name) " says " what "!"))})
(defn make-dog
  [name]
  (table/setproto @{:name name} Dog))

(assert (= "fido" ((make-dog "fido") :name)) "oo 1")
(def spot (make-dog "spot"))
(assert (= "spot says hi!" (:bark spot "hi")) "oo 2")

# Negative tests
# 67f26b7d7
(assert-error "+ check types" (+ 1 ()))
(assert-error "- check types" (- 1 ()))
(assert-error "* check types" (* 1 ()))
(assert-error "/ check types" (/ 1 ()))
(assert-error "band check types" (band 1 ()))
(assert-error "bor check types" (bor 1 ()))
(assert-error "bxor check types" (bxor 1 ()))
(assert-error "bnot check types" (bnot ()))

# Comparisons
# 10dcbc639
(assert (> 1e23 100) "less than immediate 1")
(assert (> 1e23 1000) "less than immediate 2")
(assert (< 100 1e23) "greater than immediate 1")
(assert (< 1000 1e23) "greater than immediate 2")

# Quasiquote bracketed tuples
# e239980da
(assert (= (tuple/type ~[1 2 3]) (tuple/type '[1 2 3]))
        "quasiquote bracket tuples")

# Regression #638
# c68264802
(compwhen
  (dyn 'ev/go)
  (assert
    (= [true :caught]
       (protect
         (try
           (do
             (ev/sleep 0)
             (with-dyns []
               (ev/sleep 0)
               (error "oops")))
           ([_err] :caught))))
    "regression #638"))

#
# Test propagation of signals via fibers
#
# b8032ec61
(def f (fiber/new (fn [] (error :abc) 1) :ei))
(def res (resume f))
(assert-error :abc (propagate res f) "propagate 1")

# Cancel test
# 28439d822
(def fc (fiber/new (fn [&] (yield 1) (yield 2) (yield 3) 4) :yti))
(assert (= 1 (resume fc)) "cancel resume 1")
(assert (= 2 (resume fc)) "cancel resume 2")
(assert (= :hi (cancel fc :hi)) "cancel resume 3")
(assert (= :error (fiber/status fc)) "cancel resume 4")

#
# Signals a cfunction raises, and the frame the raise leaves behind
#
# A cfunction returns its raise and run_vm propagates it, so a non-error signal
# is the case that distinguishes carrying the signal unaltered from re-raising
# it as an error.
(def fs (fiber/new (fn [] (signal 3 :payload)) :i0123456789))
(assert (= :payload (resume fs)) "user signal from a cfunction carries its value")
(assert (= :user3 (fiber/status fs)) "user signal from a cfunction keeps its number")

(def fst (fiber/new (fn [] (defn g [] (signal 5 :deep)) (g)) :i0123456789))
(assert (= :deep (resume fst)) "user signal at a tail call carries its value")
(assert (= :user5 (fiber/status fst)) "user signal at a tail call keeps its number")

# A cfunction that raises must leave its own frame on the stack, or the trace
# loses the function that actually failed.
(def fe (fiber/new (fn [] (defn g [x] (string/ascii-upper x)) (g 7)) :ei))
(resume fe)
(assert (= :error (fiber/status fe)) "cfunction error is an error")
(def frames (debug/stack fe))
(assert (= 2 (length frames)) "cfunction error leaves the c frame unpopped")
(assert (get (first frames) :c) "the unpopped frame is the cfunction's")
(assert (= "string/ascii-upper" (get (first frames) :name))
        "the unpopped frame names the cfunction")

# A signal raised inside a Janet callback that a cfunction invoked has to
# unwind through the cfunction's frame the same way. A PEG function capture is
# the cheapest cfunction that calls back into Janet, so this region needs the
# matcher and is compiled out of a build without it.
(compwhen (dyn 'peg/match)
  (def fp (fiber/new (fn [] (peg/match ~(/ '1 ,(fn [_] (error :grammar))) "abc")) :ei))
  (assert (= :grammar (resume fp)) "error from a peg callback reaches the fiber")
  (assert (= :error (fiber/status fp)) "error from a peg callback is an error"))

#
# Operator method fallback, and signals raised inside it
#
# The arithmetic, bitwise and comparison opcodes take a number fast path and
# fall back to a method lookup for anything else. That fallback has to be right
# on both paths: the value comes back and the VM's stack pointer is refreshed,
# or the raise comes back and nothing after the call runs.
(def adder @{:+ (fn [_self other] [:added other])})
(assert (= [:added 5] (+ adder 5)) "binary operator falls back to a method")
(assert (= [:added 5] (+ adder 5) (+ adder 5)) "method fallback refreshes the stack")

(def shifter @{:<< (fn [_self other] [:shifted other])})
(assert (= [:shifted 2] (blshift shifter 2)) "bitwise operator falls back to a method")

(def notter @{(keyword "~") (fn [_self] :notted)})
(assert (= :notted (bnot notter)) "unary operator falls back to a method")

(assert-error "could not find method :+ for :x" (+ :x :y)
              "missing binary method raises")
(assert-error "could not find method :+ for :x" (+ :x 1)
              "missing method raises for the immediate form too")

(def thrower @{:+ (fn [_self _other] (error :from-method))})
(assert-error :from-method (+ thrower 1) "a raising method propagates its value")
(def fm (fiber/new (fn [] (defn g [x] (+ thrower x)) (g 1)) :ei))
(resume fm)
(assert (= :error (fiber/status fm)) "a raising method leaves the fiber in error")
(assert (= :from-method (fiber/last-value fm)) "a raising method keeps its value")

# The data-access opcodes are routed the same way, so their messages have to
# survive the round trip unchanged.
(assert-error "expected integer key for tuple, got :k" (in [1 2 3] :k) "in raises")
(assert-error "expected iterable, got 7" (next 7 nil) "next raises")
(assert-error "expected abstract|array|buffer|dictionary|string|symbol|keyword|tuple, got 7"
              (length 7) "length raises")
(assert-error "cannot put value in immutable type" (put [1 2 3] 0 :v) "put raises")

# The collector's frame walk, against a collection that really happens.
#
# A change to the fiber's frame fields once broke `markFiber`'s walk so that a
# frame's locals were never marked, and **all 65 contracts passed**; only the
# bootstrap noticed, and its only symptom was a bare `exit 1`. Nothing in the
# tree drove a collection with several live frames under it, which is the one
# state the walk exists for.
#
# Each frame holds four locals that exist nowhere else -- freshly built, not
# interned, not reachable from any global -- so a frame the walk skips has its
# strings and arrays freed. The churn after the collection is what makes that
# observable rather than merely undefined: it reallocates the sizes just freed,
# so a local whose block was released comes back holding something else.
(defn- frame-locals [n]
  (def s (string "frame-" n "-string"))
  (def b (buffer "frame-" n "-buffer"))
  (def a @[n (string "frame-" n "-elem")])
  (def tab @{:depth n :name (string "frame-" n "-name")})
  (if (zero? n)
    (do
      (gccollect)
      # Reallocate the sizes just released, so a freed local is overwritten
      # rather than left readable.
      (loop [i :range [0 4000]]
        (def junk @[(string "junk-" i) (buffer "junk-" i)])
        junk)
      (gccollect))
    (frame-locals (dec n)))
  # Every local of this frame, checked on the way back out.
  (assert (= s (string "frame-" n "-string")) (string "frame " n " string local survives"))
  (assert (= (string b) (string "frame-" n "-buffer")) (string "frame " n " buffer local survives"))
  (assert (= (a 0) n) (string "frame " n " array local survives"))
  (assert (= (a 1) (string "frame-" n "-elem")) (string "frame " n " array element survives"))
  (assert (= (tab :depth) n) (string "frame " n " table local survives"))
  (assert (= (tab :name) (string "frame-" n "-name")) (string "frame " n " table value survives"))
  n)

(assert (= 24 (frame-locals 24)) "a collection under 25 live frames keeps every local")

# The same walk over a *suspended* fiber, which is the other arm: those frames
# are not the collector's caller's, so `markFiber` reaches them through the
# fiber object rather than through the root set.
(def suspended
  (fiber/new (fn []
               (def held @[(string "held-by-a-suspended-frame")])
               (defn inner [depth]
                 (def mine (string "suspended-" depth))
                 (if (zero? depth)
                   (yield :ready)
                   (inner (dec depth)))
                 (assert (= mine (string "suspended-" depth))
                         (string "suspended frame " depth " local survives")))
               (inner 12)
               (assert (= (held 0) (string "held-by-a-suspended-frame"))
                       "the outermost suspended frame's local survives")
               :done)))
(assert (= :ready (resume suspended)) "the fiber suspends inside its innermost frame")
(gccollect)
(loop [i :range [0 4000]] (def junk @[(string "junk-" i) (buffer "junk-" i)]) junk)
(gccollect)
(assert (= :done (resume suspended)) "the suspended fiber's frames survive a collection")

# A shift is a wrapping shift and its count is taken modulo the operand's
# width. C leaves all three of these undefined -- a negative left operand, an
# overflow into the sign bit, and a count at or beyond the width -- and this
# runtime answers them, so a program may rely on the answers.
(assert (= -16 (blshift -8 1)) "a left shift of a negative value wraps")
(assert (= -2147483648 (blshift 1 31)) "a left shift into the sign bit wraps")
(assert (= 1 (blshift 1 32)) "a shift count is taken modulo 32")
(assert (= 2 (blshift 1 33)) "and again past the width")
(assert (= -4 (brshift -8 33)) "the signed right shift takes the count the same way")
(assert (= 2013265920 (brushift 4026531840 33))
        "and so does the unsigned one")

(end-suite)

