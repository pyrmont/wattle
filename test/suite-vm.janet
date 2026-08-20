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
# it as an error. This was the per-call try scope's job under -Dcall-trampoline,
# which the hinge spent along with the last setjmp.
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

(end-suite)

