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

(setdyn *lint-warn* :none)

# The assembler and disassembler are absent from a build without
# JANET_ASSEMBLER, and an absent binding is a compile error rather than a
# runtime one. Janet compiles and runs a file one top-level form at a time, so
# leaving here keeps the rest of the suite from reaching the compiler at all.
(compwhen (not (dyn 'asm))
  (end-suite)
  (os/exit 0))

# Assembly test
# Fibonacci sequence, implemented with naive recursion.
# a679f60
(def fibasm (asm '{
  :arity 1
  :bytecode [
    (ltim 1 0 0x2)      # $1 = $0 < 2
    (jmpif 1 :done)     # if ($1) goto :done
    (lds 1)             # $1 = self
    (addim 0 0 -0x1)    # $0 = $0 - 1
    (push 0)            # push($0), push argument for next function call
    (call 2 1)          # $2 = call($1)
    (addim 0 0 -0x1)    # $0 = $0 - 1
    (push 0)            # push($0)
    (call 0 1)          # $0 = call($1)
    (add 0 0 2)        # $0 = $0 + $2 (integers)
    :done
    (ret 0)             # return $0
  ]
}))

(assert (= 0 (fibasm 0)) "fibasm 1")
(assert (= 1 (fibasm 1)) "fibasm 2")
(assert (= 55 (fibasm 10)) "fibasm 3")
(assert (= 6765 (fibasm 20)) "fibasm 4")

# dacbe29
(def f (asm (disasm (fn [x] (fn [y] (+ x y))))))
(assert (= ((f 10) 37) 47) "asm environment tables")

# issue #1424
(assert-no-error "arity > used slots (issue #1424)"
                 (asm
                   (disasm
                     (fn []
                       (def foo (fn [one two] one))
                       (foo 100 200)))))

# A failed nested assembly reports the child's message at the top level.
#
# Until Phase 10 Part 3 this path had two mechanisms and no coverage: the child
# longjmped into the parent's handler having copied its message across, which
# made the parent's own check on the child's result unreachable. That check is
# the live path now, and a mutation sweep found nothing anywhere noticed when it
# was removed -- the assembler stored a null funcdef instead of failing.
(assert-error "nested assembly failure propagates"
              (asm {:arity 0
                    :bytecode ['(ret 0)]
                    :defs [{:arity 0 :bytecode ['(bogus-op 0)]}]}))

(let [[ok err] (protect (asm {:arity 0
                              :bytecode ['(ret 0)]
                              :defs [{:arity 0 :bytecode ['(bogus-op 0)]}]}))]
  (assert (not ok) "nested assembly failure is an error")
  (assert (string/find "bogus-op" (string err))
          "nested assembly failure names the child's instruction"))

(end-suite)

