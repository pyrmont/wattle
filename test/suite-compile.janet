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

# Regression Test
# 0378ba78
(assert (= 1 (((compile '(fn [] 1) @{})))) "regression test")

# Fix a compiler bug in the do special form
# 3e1e2585
(defn myfun [x]
  (var a 10)
  (set a (do
         (def _y x)
         (if x 8 9))))

(assert (= (myfun true) 8) "check do form regression")
(assert (= (myfun false) 9) "check do form regression")

# Check x:digits: works as symbol and not a hex number
# 5baf70f4
(def x1 100)
(assert (= x1 100) "x1 as symbol")
(def X1 100)
(assert (= X1 100) "X1 as symbol")

# Edge case should cause old compilers to fail due to
# if statement optimization
# 17283241
(setdyn *lint-warn* :relaxed)
(var var-a 1)
(var var-b (if false 2 (string "hello")))
(setdyn *lint-warn* nil)

(assert (= var-b "hello") "regression 1")

# d28925fda
(assert (= (string '()) (string [])) "empty bracket tuple literal")

# Bracket tuple issue
# 340a6c4
(let [do 3]
  (assert (= [3 1 2 3] [do 1 2 3]) "bracket tuples are never special forms"))
(assert (= ~(,defn 1 2 3) [defn 1 2 3]) "bracket tuples are never macros")
(assert (= ~(,+ 1 2 3) [+ 1 2 3]) "bracket tuples are never function calls")

# Crash issue #1174 - bad debug info
# e97299f
(defn crash []
  (debug/stack (fiber/current)))
(do
  (math/random)
  (defn foo [_]
    (crash)
    1)
  (foo 0)
  10)

# Issue #1699 - fuzz case with bad def
(def result
  (compile '(defn sum3
              "Solve the 3SUM problem in O(n^2) time."
              [s]
              (def)tab @{})))
(assert (get result :error) "bad sum3 fuzz issue valgrind")

# Issue #1700
(def result1
  (compile
    '(defn fuzz-case-1
      [start end &]
      (if end
        (if e start (lazy-range (+ 1 start) end)))
      1)))
(assert (get result1 :error) "fuzz case issue #1700")

# Issue #1702 - fuzz case with upvalues
(def result2
  (compile
  '(each item [1 2 3]
    # Generate a lot of upvalues (more than 224)
    (def ;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;out-buf @"")
    (with-dyns [:out out-buf] 1))))
(assert result2 "bad upvalues fuzz case")

# Named argument linting
# Enhancement for #1654

(defn fnamed [&named x y z] [x y z])
(defn fkeys [&keys ks] ks)
(defn fnamed2 [_a _b _c &named x y z] [x y z])
(defn fkeys2 [_a _b _c &keys ks] ks)
(defn fnamed3 [{:x x} &named a b c] [x a b c])
(defn fnamed4 [_y &opt _z &named a b c] [a b c])
(defn fnamed5 [&opt _z &named a b c] [a b c])
(defn g [x &opt y &named z] [x y z])

(defn check-good-compile
  [code msg]
  (def lints @[])
  (def result4 (compile code (curenv) "suite-compile.janet" lints))
  (assert (and (function? result4) (empty? lints)) msg))

(defn check-lint-compile
  [code msg]
  (def lints @[])
  (def result4 (compile code (curenv) "suite-compile.janet" lints))
  (assert (and (function? result4) (next lints)) msg))

(check-good-compile '(fnamed) "named no args")
(check-good-compile '(fnamed :x 1 :y 2 :z 3) "named full args")
(check-lint-compile '(fnamed :x) "named odd args")
(check-lint-compile '(fnamed :w 0) "named wrong key args")
(check-good-compile '(fkeys :a 1) "keys even args")
(check-lint-compile '(fkeys :a 1 :b) "keys odd args")
(check-good-compile '(fnamed2 nil nil nil) "named 2 no args")
(check-good-compile '(fnamed2 nil nil nil :x 1 :y 2 :z 3) "named 2 full args")
(check-lint-compile '(fnamed2 nil nil nil :x) "named 2 odd args")
(check-lint-compile '(fnamed2 nil nil nil :w 0) "named 2 wrong key args")
(check-good-compile '(fkeys2 nil nil nil :a 1) "keys 2 even args")
(check-lint-compile '(fkeys2 nil nil nil :a 1 :b) "keys 2 odd args")
(check-good-compile '(fnamed3 {:x 1} :a 1 :b 2 :c 3) "named 3 good")
(check-lint-compile '(fnamed3 {:x 1} :a 1 :b 2 :d 3) "named 3 lint")
(check-good-compile '(fnamed4 10 20 :a 1 :b 2 :c 3) "named 4 good")
(check-lint-compile '(fnamed4 10 20 :a 1 :b 2 :d 3) "named 4 lint")
(check-good-compile '(fnamed5 10 :a 1 :b 2 :c 3) "named 5 good")
(check-lint-compile '(fnamed5 10 :a 1 :b 2 :d 3) "named 5 lint")
(check-good-compile '(g 1) "g good 1")
(check-good-compile '(g 1 2) "g good 2")
(check-good-compile '(g 1 2 :z 10) "g good 3")
(check-lint-compile '(g 1 2 :z) "g lint 1")
(check-lint-compile '(g 1 2 :z 4 5) "g lint 2")

# Variable shadowing linting
(def outer1 "a")
(check-lint-compile '(def outer1 "b") "shadow global-to-global")
(check-lint-compile '(let [outer1 "b"] outer1) "shadow local-to-global")
(check-lint-compile '(do (def x "b") (def x "c")) "shadow local-to-local")

(check-lint-compile '(def [xxx [xxx yyy]] [1 [2 3]]) "shadow global-to-global one form")

# The content of a lint, not just its presence: the level, the position and the
# interpolated message.
(defn lints-of
  [code]
  (def lints @[])
  (compile code (curenv) "lint-src" lints)
  lints)

(defn errof2
  [code env]
  (def r (compile code env "lint-src"))
  (if (table? r) (get r :error) :ok))

(defn errof
  [code]
  (errof2 code (curenv)))

(def unused-lints (lints-of '(do (def unused-binding-here 1) 2)))
(assert (= 1 (length unused-lints)) "one unused lint")
(def [level line col msg] (first unused-lints))
(assert (= :strict level) "unused lint is strict")
(assert (and (number? line) (number? col)) "unused lint carries a position")
(assert (= msg "binding unused-binding-here is unused") "unused lint message")

(assert (= :strict (first (first (lints-of '(do (def print 1) print)))))
        "shadowing a top-level binding is a strict lint")

# Deprecation lints, one per level, in the order the bindings are referenced.
(def depenv (make-env))
(put depenv 'dep-r @{:value 1 :deprecated :relaxed})
(put depenv 'dep-n @{:value 1 :deprecated :normal})
(put depenv 'dep-s @{:value 1 :deprecated :strict})
(def dep-lints @[])
(compile '(do dep-r dep-n dep-s) depenv "lint-src" dep-lints)
(assert (deep= @[:relaxed :normal :strict] (map first dep-lints)) "deprecation levels")
(assert (= "dep-r is deprecated" (last (first dep-lints))) "deprecation message")

# A compile that collects no lints must still compile; the message is simply
# not built. This is the `lints == NULL` short circuit.
(assert (function? (compile '(do (def unused2 1) 2) (curenv) "lint-src"))
        "no lint array is not an error")

# Arity diagnostics. Each is a compile error rather than a lint, and the
# singular/plural in the message is chosen by the bound rather than the count.
(defn arity1 [a] a)
(defn arity2 [a _b] a)
(assert (= "<function arity1> expects at most 1 argument, got 2" (errof '(arity1 1 2)))
        "at most, singular")
(assert (= "<function arity2> expects at most 2 arguments, got 3" (errof '(arity2 1 2 3)))
        "at most, plural")
(assert (= "<function arity1> expects at least 1 argument, got 0" (errof '(arity1)))
        "at least, singular")
(assert (= "<function arity2> expects at least 2 arguments, got 1" (errof '(arity2 1)))
        "at least, plural")
(assert (= "<function arity2> expects at most 2 arguments, got at least 3"
           (errof '(arity2 ;[1] 2 3 4)))
        "at most, with a splice")
(assert (= ":kw expects at least 1 argument, got 0" (errof '(:kw)))
        "keyword call with no argument")
(assert (= "1 expects 1 argument, got 2" (errof '(1 2 3)))
        "indexing call with too many arguments")
(assert (= "1 expects 1 argument, got 0" (errof '(1)))
        "indexing call with no argument")

# The two escapes into user code.
(def missing (make-env))
(put missing :missing-symbol (fn [_s] @{:value 42}))
(assert (= 42 ((compile 'nope missing "lint-src"))) "missing-symbol handler")
(def missing-bad (make-env))
(put missing-bad :missing-symbol (fn [a _b] a))
(assert (= "missing symbol lookup handler must take 1 argument" (errof2 '(nope) missing-bad))
        "missing-symbol arity")
(def missing-err (make-env))
(put missing-err :missing-symbol (fn [_s] (error "handler boom")))
(assert (= "(lookup) handler boom" (errof2 '(nope) missing-err)) "missing-symbol error")
(def missing-junk (make-env))
(put missing-junk :missing-symbol 17)
(assert (= "invalid lookup handler 17" (errof2 '(nope) missing-junk)) "missing-symbol not callable")
(assert (= "unknown symbol definitely-not-bound" (errof '(definitely-not-bound)))
        "unknown symbol")

(defmacro boom-macro [_a] (error "macro boom"))
(assert (= "(macro) macro boom" (errof '(boom-macro 1))) "macro error")
(assert (= "macro arity mismatch, expected at least 1, got 0" (errof '(boom-macro)))
        "macro too few arguments")
(assert (= "macro arity mismatch, expected at most 1, got 2" (errof '(boom-macro 1 2)))
        "macro too many arguments")

# The lint's position is the form's, and the two numbers are not
# interchangeable. The form is built through a parser with its line and column
# set explicitly, so both are known here rather than depending on where in this
# file the test happens to sit.
(def pos-parser (parser/new))
(parser/where pos-parser 7 0)
(parser/consume pos-parser "  (do (def pos-probe 1) 2)")
(parser/eof pos-parser)
(def pos-lints @[])
(compile (parser/produce pos-parser) (curenv) "lint-src" pos-lints)
(assert (deep= [:strict 7 3 "binding pos-probe is unused"] (tuple ;(first pos-lints)))
        "lint line and column, in that order")

# A form built at runtime carries no source map at all, and the lint records
# nil rather than the -1 the mapping actually holds.
(def unmapped-lints (lints-of (tuple 'do (tuple 'def 'unmapped-unused 1) 2)))
(assert (deep= [:strict nil nil "binding unmapped-unused is unused"]
               (tuple ;(first unmapped-lints)))
        "an absent source mapping is nil, not -1")

# The unused-binding lint is filed from two places -- when a named slot goes
# out of scope, and when a function scope is popped -- and both are strict.
(assert (= :strict (first (first (lints-of '(fn [] (def fn-local-unused 1) 2)))))
        "unused lint inside a function scope")

# A missing-symbol handler may take its argument optionally: the check is that
# the handler *can* be called with one argument, not that it must be.
(def opt-handler-env (make-env))
(put opt-handler-env :missing-symbol (fn [&opt _s] @{:value 7}))
(assert (= 7 ((compile 'nope opt-handler-env "lint-src"))) "an &opt handler is accepted")

# A macro that fails leaves its fiber on the result for the caller to inspect,
# and leaves nothing behind in the environment.
(def macro-env (make-env))
(eval '(defmacro failing-macro [_a] (error "mb")) macro-env)
(def macro-result (compile '(failing-macro 1) macro-env "lint-src"))
(assert (= :fiber (type (get macro-result :fiber))) "the failing macro fiber is attached")
(assert (nil? (get macro-env :macro-form)) "macro-form is cleared afterwards")
(assert (nil? (get macro-env :macro-lints)) "macro-lints is cleared afterwards")

# A compile error carries a position only when the form had one.
(def unmapped-error (compile (tuple 'no-such-symbol-at-all) (curenv) "lint-src"))
(assert (and (nil? (get unmapped-error :line)) (nil? (get unmapped-error :column)))
        "an unmapped compile error reports no position")
(def mapped-error (compile '(no-such-symbol-at-all) (curenv) "lint-src"))
(assert (and (number? (get mapped-error :line)) (number? (get mapped-error :column)))
        "a mapped compile error reports one")

# The builtin optimizers' identities and their degenerate arities.
(assert (= 1 (*)) "the identity for * is 1")
(assert (= 0 (+)) "the identity for + is 0")
(assert (= 1 (/ 1)) "the identity for / is 1")
(assert (deep= @[true true true true true false]
               @[(< 1) (> 1) (<= 1) (>= 1) (= 1) (not= 1)])
        "a comparison of fewer than two values")

(end-suite)
