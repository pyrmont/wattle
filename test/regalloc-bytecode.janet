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

(import ./helper :prefix "" :exit true)
(start-suite)

(def allocation-shape
  (disasm
    (fn [a b c]
      (let [x (+ a b)
            y (* b c)]
        (if (> x y) [x y] [y x])))))

(assert (= 7 (in allocation-shape :slotcount))
        "compiler register slot count")
(assert
  (deep=
    @['(add 3 0 1) '(movn 4 3) '(mul 3 1 2) '(movn 5 3)
      '(gt 3 4 5) '(jmpno 3 4) '(push2 4 5) '(mktup 6)
      '(ret 6) '(push2 5 4) '(mktup 6) '(ret 6)]
    (in allocation-shape :bytecode))
  "compiler register allocation bytecode")

(end-suite)
